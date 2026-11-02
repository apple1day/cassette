#!/usr/bin/env bash
# Cassette: back up matching profiles, provision, rebuild, verify and install.
# Requires macOS, Xcode 26+, Python 3, a signed-in Xcode account and a paired device.
# Usage: bash refresh-cassette-signing.sh [repository-directory] [device-UDID]
set -euo pipefail
umask 077

fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf '%s\n' \
    '用法：bash refresh-cassette-signing.sh [Cassette 项目目录] [iPhone/iPad UDID]' \
    '省略目录时使用脚本所在的仓库根目录；仅连接一台可用真机时自动选中。' \
    '先保存并完全退出 Xcode；手机需解锁、信任此 Mac 并开启开发者模式。' \
    '工程须已配置原来的 Team 和自动签名；依赖使用 Swift Package Manager。' \
    '脚本不切换 Git 分支、不重建工程、不卸载 App、不撤销证书。' \
    '退出码 0：签名/安装完成；1：执行失败；2：安装完成但有效期未延长。'
  exit 0
fi
[[ $# -le 2 ]] || fail '最多接收项目目录和设备 UDID 两个参数。'
[[ "$(uname -s)" == Darwin ]] || fail '请在安装完整 Xcode 的 Mac 上运行。'
if pgrep -x Xcode >/dev/null; then
  fail '请先保存工程，按 Command + Q 完全退出 Xcode，再运行。'
fi
for cassette_tool in xcodebuild xcrun python3 security codesign; do
  command -v "$cassette_tool" >/dev/null || fail "未找到 $cassette_tool，请先安装/选择完整 Xcode。"
done
cassette_xcode_version="$(xcodebuild -version)" || fail 'Xcode 尚不可用，请先打开 Xcode 完成首次设置。'
[[ "$cassette_xcode_version" =~ Xcode[[:space:]]([0-9]+) ]] || fail '无法识别 Xcode 版本。'
[[ "${BASH_REMATCH[1]}" -ge 26 ]] || fail '此 Cassette 工程需要 Xcode 26 或更新版本。'
xcrun --find devicectl >/dev/null || fail '需要 Xcode 26 或更新版本及其 devicectl。'

cassette_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cassette_root="$(cd "${1:-$cassette_script_dir}" && pwd -P)" || fail '项目目录不存在。'
cassette_project="$cassette_root/Cassette.xcodeproj"
[[ -f "$cassette_project/project.pbxproj" ]] || fail '这里没有 Cassette.xcodeproj，请指定 cassette 仓库根目录。'
[[ -f "$cassette_project/xcshareddata/xcschemes/Cassette.xcscheme" ]] || fail '缺少共享的 Cassette scheme，请先拉取完整仓库。'
cd "$cassette_root"
cassette_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cassette-signing-refresh.XXXXXX")"
trap 'rm -rf -- "$cassette_tmp"' EXIT
cassette_derived="$HOME/Library/Developer/Xcode/DerivedData/Cassette-SignRefresh"

cat > "$cassette_tmp/helper.py" <<'PY'
import datetime as dt
import fnmatch
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

UTC = dt.timezone.utc
def date(value):
    if not isinstance(value, dt.datetime):
        raise ValueError('描述文件缺少有效日期。')
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
def stamp(value):
    return date(value).astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')
def profile(path):
    raw = subprocess.run(['security', 'cms', '-D', '-i', str(path)],
                         capture_output=True, check=True).stdout
    return plistlib.loads(raw)
def eligible(p, bundle, team, device):
    appid = p.get('Entitlements', {}).get('application-identifier', '')
    pattern = appid.split('.', 1)[1] if '.' in appid else ''
    devices = [str(x).lower() for x in p.get('ProvisionedDevices', [])]
    return (team in p.get('TeamIdentifier', []) and bool(pattern)
            and fnmatch.fnmatchcase(bundle, pattern)
            and (device.lower() in devices or p.get('ProvisionsAllDevices') is True))
def app_components(app):
    app = pathlib.Path(app)
    return [app, *sorted((app / 'PlugIns').glob('*.appex'))]
def baseline_entry(p):
    appid = p.get('Entitlements', {}).get('application-identifier', '')
    return {'pattern': appid.split('.', 1)[1] if '.' in appid else '',
            'expiration': date(p['ExpirationDate']).isoformat()}
def run():
    mode, *args = sys.argv[1:]
    if mode == 'device':
        source, out, requested = args
        devices = json.loads(pathlib.Path(source).read_text())
        if not isinstance(devices, list):
            raise ValueError('无法解析 xcdevice 的设备列表。')
        devices = [d for d in devices if not d.get('simulator', False)
                   and d.get('platform') == 'com.apple.platform.iphoneos'
                   and d.get('available') is True and d.get('identifier')]
        matches = [d for d in devices if not requested or d['identifier'].lower() == requested.lower()]
        if len(matches) != 1:
            for d in devices:
                print('可用真机：%s  UDID=%s' % (d.get('name', '未命名'), d['identifier']), file=sys.stderr)
            raise ValueError('请只连接一台可用 iPhone/iPad，或把上面对应 UDID 作为脚本第二个参数。'
                             '若无设备，请解锁手机、信任此 Mac 并开启开发者模式。')
        chosen = matches[0]
        pathlib.Path(out, 'device').write_text(chosen['identifier'])
        print('目标设备：%s (%s)' % (chosen.get('name', 'iPhone/iPad'), chosen['identifier']))
    elif mode == 'settings':
        source, out = args
        items = json.loads(pathlib.Path(source).read_text())
        matches = [x['buildSettings'] for x in items if x.get('target') == 'Cassette']
        if len(matches) != 1:
            raise ValueError('没有唯一的 Cassette 主 App target，已停止。')
        settings = matches[0]
        bundle = settings.get('PRODUCT_BUNDLE_IDENTIFIER', '')
        team = settings.get('DEVELOPMENT_TEAM', '')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]+', bundle) or '.' not in bundle:
            raise ValueError('工程没有可用的 Bundle Identifier。')
        if bundle == 'com.anxiong.nicevideos' or bundle.startswith('com.anxiong.nicevideos.'):
            raise ValueError('这个 Cassette target 使用了 NiceVideos 的 Bundle ID，请先修正工程。')
        if not re.fullmatch(r'[A-Z0-9]{10}', team):
            raise ValueError('工程未配置有效 Team。请在 Xcode 的 Signing & Capabilities 选择原来的 Team，保存并退出后重试。')
        if settings.get('CODE_SIGN_STYLE') != 'Automatic':
            raise ValueError('当前不是自动签名。请在 Cassette target 勾选 Automatically manage signing，保留原 Team 和 Bundle ID，保存并退出后重试。')
        product = settings.get('FULL_PRODUCT_NAME', '')
        directory = pathlib.Path(settings.get('TARGET_BUILD_DIR', ''))
        if not directory.is_absolute() or pathlib.Path(product).name != product or not product.endswith('.app'):
            raise ValueError('无法确认本次 App 构建输出路径，已停止。')
        for name, value in [('bundle', bundle), ('team', team), ('app', str(directory / product))]:
            pathlib.Path(out, name).write_text(value)
        print('当前工程：Cassette\nBundle ID：%s\nTeam：%s' % (bundle, team))
    elif mode == 'backup':
        home, backup, bundle, team, device, app = args
        backup = pathlib.Path(backup)
        records, baselines = [], []
        for old_component in app_components(app):
            try:
                with (old_component / 'Info.plist').open('rb') as stream:
                    old_id = plistlib.load(stream).get('CFBundleIdentifier', '')
                if old_id != bundle and not old_id.startswith(bundle + '.'):
                    continue
                p = profile(old_component / 'embedded.mobileprovision')
                if eligible(p, old_id, team, device):
                    baselines.append(baseline_entry(p))
            except (ValueError, KeyError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException):
                pass
        folders = ['Library/Developer/Xcode/UserData/Provisioning Profiles',
                   'Library/MobileDevice/Provisioning Profiles']
        for folder in folders:
            for file in sorted((pathlib.Path(home) / folder).glob('*.mobileprovision')):
                if not file.is_file() or file.is_symlink():
                    continue
                try:
                    p = profile(file)
                    appid = p.get('Entitlements', {}).get('application-identifier', '')
                    suffix = appid.split('.', 1)[1] if '.' in appid else ''
                    if team not in p.get('TeamIdentifier', []):
                        continue
                    if eligible(p, suffix if '*' not in suffix else bundle, team, device):
                        if suffix == bundle or suffix.startswith(bundle + '.') or '*' in suffix:
                            baselines.append(baseline_entry(p))
                    if '*' in suffix:
                        if fnmatch.fnmatchcase(bundle, suffix):
                            print('保留共享通配描述文件：%s（可能被其他 App 使用）' % appid)
                        continue
                    if suffix != bundle and not suffix.startswith(bundle + '.'):
                        continue
                    expiry = stamp(p['ExpirationDate'])
                except (ValueError, KeyError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException):
                    continue
                dest = backup / 'profiles' / str(len(records) + 1) / file.name
                dest.parent.mkdir(parents=True, exist_ok=True)
                record = {'original': str(file), 'backup': str(dest), 'application_id': appid,
                          'uuid': p.get('UUID', ''), 'expiration': expiry}
                # Record each intended move before performing it, for recovery.
                records.append(record)
                (backup / 'profile-manifest.json').write_text(json.dumps(records, ensure_ascii=False, indent=2))
                shutil.move(str(file), str(dest))
                print('已备份：%s；旧到期时间：%s' % (appid, expiry))
        (backup / 'baseline.json').write_text(json.dumps({'profiles': baselines}))
        print('共备份 %d 份当前 Team 的 Cassette 描述文件。' % len(records))
    elif mode == 'verify':
        app, bundle, team, device, backup = args
        app, backup = pathlib.Path(app), pathlib.Path(backup)
        baselines = json.loads((backup / 'baseline.json').read_text())['profiles']
        components, new_dates, old_dates = [], [], []
        for component in app_components(app):
            if component.is_symlink():
                raise ValueError('App/扩展路径为符号链接，已停止安装。')
            with (component / 'Info.plist').open('rb') as stream:
                component_id = plistlib.load(stream).get('CFBundleIdentifier', '')
            if (component == app and component_id != bundle) or (
                    component != app and not component_id.startswith(bundle + '.')):
                raise ValueError('生成的 App/扩展 Bundle ID 不匹配，已停止安装：' + component.name)
            p = profile(component / 'embedded.mobileprovision')
            if not eligible(p, component_id, team, device):
                raise ValueError('新包描述文件与 Bundle ID / Team / 设备不匹配，已停止安装：' + component.name)
            expires = date(p['ExpirationDate'])
            if expires <= dt.datetime.now(UTC):
                raise ValueError('新包包含已过期描述文件，已停止安装：' + component.name)
            new_dates.append(expires)
            old_candidates = [dt.datetime.fromisoformat(x['expiration']) for x in baselines
                              if fnmatch.fnmatchcase(component_id, x['pattern'])]
            if old_candidates:
                old_dates.append(max(old_candidates))
            summary = {'bundle_id': component_id, 'uuid': p.get('UUID', ''),
                       'creation': stamp(p['CreationDate']), 'expiration': stamp(p['ExpirationDate'])}
            components.append(summary)
            print('签名组件：%s\n描述文件 UUID：%s\n创建时间：%s\n到期时间：%s\n' %
                  (component_id, summary['uuid'], summary['creation'], summary['expiration']))
        expires = min(new_dates)
        # Compare complete sets of app/extension profiles, not an app date with
        # an unrelated widget or another team's profile.
        old = min(old_dates) if len(old_dates) == len(components) else None
        result = {'components': components, 'expiration': stamp(expires),
                  'baseline_expiration': stamp(old) if old else None,
                  'extended': expires > old if old else None}
        (backup / 'signing-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    elif mode == 'result':
        backup, = args
        result = json.loads(pathlib.Path(backup, 'signing-result.json').read_text())
        print('\n重新签名并覆盖安装完成。App 与扩展中最早到期时间：%s' % result['expiration'])
        print('请打开小熊音乐（Cassette）→ 我的 → 签名有效期 → 重新检查签名与提醒。')
        print('App 内显示的是主 App 的到期时间；本脚本汇总主 App 与 Widget 中最早到期的一项。')
        if result['extended'] is False:
            print('注意：有效期未超过本机旧 App/扩展描述文件组合的到期时间：%s。' % result['baseline_expiration'])
            print('本次完成了重新签名和安装，但尚不能认定已续期；Apple 可能返回或复用了同一期限的描述文件。')
            return 2
        if result['extended'] is True:
            print('有效期已延长；本机旧 App/扩展描述文件组合到期时间：%s。' % result['baseline_expiration'])
        else:
            print('本机没有完整的旧 App/扩展描述文件可供比较；以上为本次实际到期时间。')
    else:
        raise ValueError('未知内部操作。')
    return 0
try:
    sys.exit(run())
except (ValueError, KeyError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as exc:
    print('错误：' + str(exc), file=sys.stderr)
    sys.exit(1)
PY

printf '\n[1/5] 检查真机与工程签名配置\n'
xcrun xcdevice list --timeout 10 > "$cassette_tmp/devices.json" || fail '无法读取真机列表。'
python3 "$cassette_tmp/helper.py" device "$cassette_tmp/devices.json" "$cassette_tmp" "${2:-${CASSETTE_DEVICE_ID:-}}"
cassette_device="$(cat "$cassette_tmp/device")"
cassette_args=(-project "$cassette_project" -scheme Cassette -configuration Debug -sdk iphoneos
  -destination "platform=iOS,id=$cassette_device" -destination-timeout 30
  -derivedDataPath "$cassette_derived" -disableAutomaticPackageResolution)
if ! xcodebuild "${cassette_args[@]}" -showBuildSettings -json > "$cassette_tmp/settings.json" 2> "$cassette_tmp/settings.err"; then
  cat "$cassette_tmp/settings.err" >&2
  fail '无法读取工程配置；请先确认 Cassette.xcodeproj 能在 Xcode 中正常打开且 SPM 依赖已解析。'
fi
python3 "$cassette_tmp/helper.py" settings "$cassette_tmp/settings.json" "$cassette_tmp"
cassette_bundle="$(cat "$cassette_tmp/bundle")"
cassette_team="$(cat "$cassette_tmp/team")"
cassette_app="$(cat "$cassette_tmp/app")"

cassette_backup="$HOME/Desktop/Cassette-Profiles-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$cassette_backup"
printf '\n[2/5] 备份当前 App 的描述文件\n备份及日志：%s\n' "$cassette_backup"
python3 "$cassette_tmp/helper.py" backup "$HOME" "$cassette_backup" "$cassette_bundle" "$cassette_team" "$cassette_device" "$cassette_app"

printf '\n[3/5] 联网请求签名资产，清理专用构建输出并重新编译\n'
if ! xcodebuild "${cassette_args[@]}" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$cassette_team" \
  PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGNING_ALLOWED=YES \
  -quiet clean build 2>&1 | tee "$cassette_backup/build.log"; then
  printf '\n构建失败，尚未安装到手机。备份及完整日志：%s\n' "$cassette_backup" >&2
  printf '%s\n' '请检查日志中的第一条签名错误；若提示账号/登录失效，先在 Xcode Settings → Accounts 重新登录。' \
    '若提示依赖下载失败，请检查 Swift Package Manager 的网络或访问权限后重试。' >&2
  exit 1
fi

printf '\n[4/5] 验证实际 App 签名与嵌入描述文件\n'
[[ -d "$cassette_app" ]] || fail "未找到构建产物：$cassette_app"
codesign --verify --deep --strict "$cassette_app" || fail 'App 签名校验未通过，已停止安装。'
python3 "$cassette_tmp/helper.py" verify "$cassette_app" "$cassette_bundle" "$cassette_team" "$cassette_device" "$cassette_backup"

printf '\n[5/5] 覆盖安装到已选中的真机\n'
if ! xcrun devicectl device install app --device "$cassette_device" "$cassette_app" 2>&1 | tee "$cassette_backup/install.log"; then
  printf '\n构建和签名已完成，但设备安装失败。请解锁手机并检查信任/开发者模式。\n日志：%s\n' "$cassette_backup/install.log" >&2
  exit 1
fi
python3 "$cassette_tmp/helper.py" result "$cassette_backup"
