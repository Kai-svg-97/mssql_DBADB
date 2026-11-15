#!/usr/bin/env python3
"""설치에 필요한 파일을 배포용 ZIP으로 묶습니다."""
from datetime import datetime
from pathlib import Path
import sys
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
FILES = [Path(p) for p in ('install.sql', 'upgrade.sql', 'README.md', 'LICENSE',
          'docs/installation.md', 'docs/operations.md')] + [
    Path('sql') / f'{n}-{name}.sql' for n, name in (
        ('00', 'bootstrap'), ('10', 'config'), ('20', 'history'), ('30', 'policy'),
        ('40', 'backup'), ('50', 'capacity'), ('60', 'tools'), ('70', 'agent'))]

def main():
    missing = [str(p) for p in FILES if not (ROOT / p).is_file()]
    if missing:
        raise SystemExit('필수 파일이 없습니다: ' + ', '.join(missing))
    destination = ROOT / 'dist'
    destination.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    archive = destination / f'DBADB_{timestamp}.zip'
    try:
        with ZipFile(archive, 'x', ZIP_DEFLATED) as z:
            for path in FILES:
                z.write(ROOT / path, path.as_posix())
    except Exception:
        archive.unlink(missing_ok=True)
        raise
    print(archive)

if __name__ == '__main__':
    main()
