#!/usr/bin/env python3
"""Install this mod into the selected RML Studio while Studio is closed."""
from pathlib import Path
import argparse
import datetime
import json
import os
import shutil
import subprocess

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--uninstall', action='store_true', help='Remove only this mod and keep all template data.')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    manager = Path.home() / 'Library/Application Support/com.revolution.rml-launcher/studio'
    if args.app:
        app = args.app.resolve()
    else:
        selected = json.loads((manager / 'settings.json').read_text())['defaultInstallationId']
        if not selected.startswith('managed:'):
            parser.error('Pass --app for a Studio installation outside the RML manager.')
        app = manager / 'versions' / selected.split(':', 1)[1] / 'RobloxStudio.app'
    executable = app / 'Contents/MacOS/RobloxStudio'
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    if str(executable) in processes:
        parser.error('Close this Studio installation before installing the mod.')
    source = project / '.agent-work/payload/mods/custom-templates'
    if not (source / 'dotnet/CustomTemplates.dll').is_file():
        source = project / 'prebuilt/mods/custom-templates'
    if not args.uninstall and not (source / 'dotnet/CustomTemplates.dll').is_file():
        parser.error('Build the mod first.')
    if not args.uninstall and not (source / 'dotnet/libCustomTemplatesUI.dylib').is_file():
        parser.error('The native helper is missing. Build the complete mod before installing.')
    mods = app / 'Contents/MacOS/RobloxModLoader/mods'
    if not mods.is_dir():
        parser.error('The selected Studio does not have an RML mods directory.')
    target = mods / 'custom-templates'
    asset_link = app / 'Contents/Resources/content/RMLCustomTemplates'
    # macOS strict signing allows external bundle links under /Library, but not
    # under /Users. This is a rebuildable, per-user cache, not the source catalog.
    thumbnail_root = Path('/Library/Caches') / ('RobloxCustomTemplates-' + str(os.getuid()))
    # Only this exact, owned alias may be changed. The source images stay in the
    # catalog; never overwrite an unrelated app resource or follow its link.
    previous_asset_link = os.readlink(asset_link) if asset_link.is_symlink() else None
    if asset_link.exists() and not asset_link.is_symlink():
        parser.error('RMLCustomTemplates asset path already exists and is not our symlink.')
    if previous_asset_link is not None and previous_asset_link != str(thumbnail_root):
        parser.error('RMLCustomTemplates asset link points to an unexpected location.')
    if args.uninstall and not target.exists() and not asset_link.is_symlink():
        print('Custom Templates is already uninstalled. Template data has been kept.')
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = project / '.agent-work/install-backups' / stamp
    backup.mkdir(parents=True)
    if target.exists():
        shutil.copytree(target, backup / 'custom-templates')
    try:
        if target.exists():
            shutil.rmtree(target)
        if not args.uninstall:
            shutil.copytree(source, target)
            thumbnail_root.mkdir(mode=0o700, parents=False, exist_ok=True)
            if thumbnail_root.is_symlink() or thumbnail_root.stat().st_uid != os.getuid():
                raise RuntimeError('The thumbnail cache is not owned by this user.')
            thumbnail_root.chmod(0o700)
            if not asset_link.is_symlink():
                asset_link.symlink_to(thumbnail_root, target_is_directory=True)
        elif asset_link.is_symlink():
            asset_link.unlink()
        subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    except BaseException as error:
        if target.exists():
            shutil.rmtree(target)
        if (backup / 'custom-templates').exists():
            shutil.copytree(backup / 'custom-templates', target)
        if asset_link.is_symlink():
            asset_link.unlink()
        if previous_asset_link is not None:
            asset_link.symlink_to(previous_asset_link, target_is_directory=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app)], capture_output=True)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors='replace'))
        raise
    receipt = {'app': str(app), 'mod': str(target), 'backup': str(backup),
               'assetLink': str(asset_link), 'thumbnailRoot': str(thumbnail_root),
               'action': 'uninstall' if args.uninstall else 'install', 'completedUtc': stamp}
    (backup / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))

if __name__ == '__main__':
    main()
