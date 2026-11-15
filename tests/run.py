#!/usr/bin/env python3
"""Integration tests on disposable Docker SQL Servers. Never connects to a host DB."""
import argparse
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def command(args, **kwargs):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, **kwargs).stdout


def test_version(version, keep):
    name = f"dbadb-it-{version}-{secrets.token_hex(4)}"
    password = "Dbadb_IT_49!" + secrets.token_hex(12)
    log_dir = ROOT / "tests" / "artifacts"
    log_dir.mkdir(exist_ok=True)
    log = log_dir / f"{version}.log"
    output = []
    started = False
    holder = None
    env = {**os.environ, "SQLCMDPASSWORD": password}
    try:
        # SQL Server 2019 Agent uses a 15-character host name for its local connection.
        hostname = f"dbadb{version}{secrets.token_hex(2)}"
        command(["docker", "run", "-d", "--name", name, "--hostname", hostname,
                 "--memory=3g", "-e", "ACCEPT_EULA=Y", "-e", "MSSQL_PID=Developer",
                 "-e", f"MSSQL_SA_PASSWORD={password}", "-e", "MSSQL_AGENT_ENABLED=true",
                 f"mcr.microsoft.com/mssql/server:{version}-latest"])
        started = True
        client = command(["docker", "exec", name, "sh", "-c",
                          "ls /opt/mssql-tools*/bin/sqlcmd | head -1"]).strip()
        base = ["docker", "exec", "-w", "/tmp/dbadb", "-e", "SQLCMDPASSWORD", name,
                client, "-S", "localhost", "-U", "sa", "-C", "-b", "-r", "1"]
        # Copy only source assets; do not mount or expose the host filesystem to SQL Server.
        with tempfile.TemporaryDirectory() as tmp:
            os.chmod(tmp, 0o755)
            for file in ("install.sql", "upgrade.sql"):
                shutil.copy(ROOT / file, tmp)
            for directory in ("sql", "tests"):
                shutil.copytree(ROOT / directory, Path(tmp) / directory,
                                ignore=shutil.ignore_patterns("artifacts", "__pycache__"))
            command(["docker", "cp", tmp + "/.", name + ":/tmp/dbadb"])
        deadline = time.monotonic() + 120
        while True:
            try:
                command(base + ["-l", "2", "-Q",
                                "IF NOT EXISTS(SELECT 1 FROM msdb.dbo.syssessions "
                                "WHERE agent_start_date >= (SELECT sqlserver_start_time FROM sys.dm_os_sys_info)) "
                                "THROW 52000,'Agent not ready',1; EXEC msdb.dbo.sp_is_sqlagent_starting;"], env=env)
                break
            except subprocess.CalledProcessError:
                if time.monotonic() > deadline:
                    raise RuntimeError("SQL Server did not become ready")
                time.sleep(1)
        output.append(command(base + ["-Q", "SELECT @@VERSION AS engine_version;"], env=env))
        # Start from a v1 database so install.sql is tested as an in-place upgrade.
        for script in ("tests/v1-fixture.sql", "install.sql", "tests/integration.sql"):
            print(f"SQL Server {version}: {script}", flush=True)
            output.append(command(base + ["-i", script, "-v",
                                         r"BackupDirectory=C:\var\opt\mssql\data"], env=env))
        print(f"SQL Server {version}: concurrent sessions", flush=True)
        command(base + ["-Q", "CREATE TABLE DBADB.dbo.IT_LockSignal(ready bit,release_lock bit); "
                        "INSERT DBADB.dbo.IT_LockSignal VALUES(0,0);"], env=env)
        holder = subprocess.Popen(base + ["-i", "tests/concurrency-hold.sql"], env=env,
                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            signal = command(base + ["-h", "-1", "-W", "-Q",
                                     "SET NOCOUNT ON; SELECT ready FROM DBADB.dbo.IT_LockSignal;"], env=env)
            if signal.strip() == "1":
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("Lock-holding session did not become ready")
        output.append(command(base + ["-i", "tests/concurrency-probe.sql"], env=env))
        command(base + ["-Q", "UPDATE DBADB.dbo.IT_LockSignal SET release_lock=1;"], env=env)
        tail, _ = holder.communicate(timeout=30)
        output.append(tail)
        if holder.returncode:
            raise RuntimeError("Lock-holding session failed")
        for script in ("install.sql", "upgrade.sql", "tests/upgrade-assertions.sql"):
            print(f"SQL Server {version}: {script}", flush=True)
            output.append(command(base + ["-i", script], env=env))
        print(f"SQL Server {version}: PASS ({log.relative_to(ROOT)})", flush=True)
    except subprocess.CalledProcessError as error:
        output.append(error.stdout or "")
        print((error.stdout or "")[-6000:], flush=True)
        raise
    finally:
        if holder is not None and holder.poll() is None:
            subprocess.run(base + ["-Q", "UPDATE DBADB.dbo.IT_LockSignal SET release_lock=1;"],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            holder.communicate(timeout=60)
        log.write_text("\n".join(output), encoding="utf-8")
        if started and not keep:
            subprocess.run(["docker", "rm", "-f", name], check=False, stdout=subprocess.DEVNULL)
        elif started:
            print(f"Kept disposable container: {name}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", choices=("2019", "2022"), action="append")
    parser.add_argument("--keep", action="store_true", help="Keep test containers for investigation")
    args = parser.parse_args()
    for selected in args.version or ("2019", "2022"):
        test_version(selected, args.keep)
