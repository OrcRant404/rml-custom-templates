#!/usr/bin/env python3
"""Create a source and prebuilt-payload ZIP without local user data or scratch."""
import argparse
from pathlib import Path
import zipfile

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    payload = project / '.agent-work/payload/mods/custom-templates'
    for name in ['CustomTemplates.dll', 'libCustomTemplatesUI.dylib']:
        if not (payload / 'dotnet' / name).is_file():
            parser.error('Build the complete mod before packaging: missing ' + name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for relative in ['README.md', 'TESTING.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', '.gitignore', '.github', 'CustomTemplates.csproj', 'src', 'native', 'scripts', 'tests']:
            path = project / relative
            for file in ([path] if path.is_file() else sorted(path.rglob('*'))):
                if not file.is_file() or any(part in ['bin', 'obj', '__pycache__', '.agent-work'] for part in file.relative_to(project).parts):
                    continue
                archive.write(file, Path('rml-custom-templates') / file.relative_to(project))
        for file in sorted(payload.rglob('*')):
            if file.is_file():
                archive.write(file, Path('rml-custom-templates/prebuilt/mods/custom-templates') / file.relative_to(payload))
    print(args.output.resolve())

if __name__ == '__main__':
    main()
