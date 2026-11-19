#!/bin/bash
set -euo pipefail

ym_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_build_only=false
if [ "${1:-}" = --build-only ]; then ym_build_only=true; shift; fi
ym_evidence="${1:-$ym_root/test-output/update-runtime}"
ym_cases=(update tampered-feed tampered-archive cancel gate-veto automatic occupied offline)
case "${YM_UPDATE_RUNTIME_CASE:-all}" in
  all) ;;
  occupied) ym_cases=(occupied) ;;
  *) printf 'Unknown runtime acceptance scenario.\n' >&2; exit 2 ;;
esac
# A disposable runner: GitHub's hosted macOS (user runner), or a Hayabuild job in a fresh VM of its own
# (runs-on: [hayabuild-macos, vm]; the runner sets HAYABUILD_DISPOSABLE_VM=1 only there, user admin).
ym_disposable_runner() {
  [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_OS:-}" = macOS ] || return 1
  { [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] && [ "$(id -un)" = runner ]; } || \
    { [ "${HAYABUILD_DISPOSABLE_VM:-}" = 1 ] && [ "$(id -un)" = admin ]; }
}
if [ "$ym_build_only" = false ] && ! ym_disposable_runner; then
  printf 'Refusing GUI/trust changes outside a disposable macOS runner (GitHub-hosted, or a Hayabuild VM). Use --build-only locally.\n' >&2
  exit 2
fi
printf '[update-runtime] build fixtures\n'
mkdir -p "$ym_evidence"
ym_evidence="$(cd "$ym_evidence" && pwd -P)"
# In a Hayabuild VM the checkout and RUNNER_TEMP are on a virtiofs share, where ditto cannot copy symbolic links
# ("Too many levels of symbolic links" on Sparkle.framework). Keep the fixtures on the VM's own disk there.
if [ "$ym_build_only" = false ] && [ "${HAYABUILD_DISPOSABLE_VM:-}" = 1 ]; then
  export RUNNER_TEMP=/private/var/tmp/yomado-runner-temp
  mkdir -p "$RUNNER_TEMP"
  export YOMADO_DEPS_DIR="${YOMADO_DEPS_DIR:-/private/var/tmp/yomado-build-deps}"
fi
ym_temp_root="$RUNNER_TEMP"
ym_sparkle="$("$ym_root/scripts/fetch-sparkle.sh")"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -g0 -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_root"=. -fmacro-prefix-map="$ym_root"=. \
  -I "$ym_root/app" -I "$ym_root/bridge" -F "$ym_sparkle" \
  "$ym_root/tests/UpdateRuntimeFixture.m" "$ym_root/app/AutomaticUpdater.m" \
  "$ym_root/app/UpdateWorkspaceRecovery.m" "$ym_root/tests/UpdateRuntimeWorkspace.m" \
  "$ym_root/bridge/VDVirtualDisplay.m" "$ym_root/bridge/YMDisplayTopology.m" \
  -framework ColorSync -framework AppKit -framework ApplicationServices \
  -framework CoreGraphics -framework Sparkle -Wl,-rpath,@executable_path/../Frameworks \
  -o "$ym_evidence/UpdateRuntimeFixture"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -g0 -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_root"=. -fmacro-prefix-map="$ym_root"=. \
  "$ym_root/tests/UpdateRuntimeWindow.m" -framework AppKit -framework CoreGraphics \
  -o "$ym_evidence/UpdateRuntimeWindow"
if [ "$ym_build_only" = true ]; then printf 'Fixture compiled; no application was launched.\n'; exit 0; fi

ym_temporary="$(mktemp -d "$ym_temp_root/yomado-update-runtime.XXXXXX")"
ym_ca_name="yomado CI Update Test ${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
ym_server_pid=""
ym_fixture_pid=""
ym_window_pids=""
ym_stop_server() {
  [ -n "$ym_server_pid" ] || return 0
  python3 - "$ym_server_pid" <<'PYSTOP'
import os,signal,subprocess,sys,time
pid=int(sys.argv[1])
def alive():
    try:
        r=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True,timeout=2)
        return r.returncode==0 and r.stdout.strip() and not r.stdout.strip().startswith('Z')
    except subprocess.TimeoutExpired:return True
try:os.kill(pid,signal.SIGTERM)
except ProcessLookupError:pass
deadline=time.monotonic()+3
while time.monotonic()<deadline and alive():time.sleep(.1)
if alive():
    try:os.kill(pid,signal.SIGKILL)
    except ProcessLookupError:pass
print('[update-runtime] server stop requested for PID '+str(pid),flush=True)
PYSTOP
  ym_server_pid=""
}
ym_bounded_guest_command() {
  python3 - "$ym_evidence/guest-cleanup.jsonl" "$@" <<'PYBOUND'
import json,os,signal,subprocess,sys,time
from pathlib import Path
path,label,seconds,*command=sys.argv[1:];started=time.monotonic();result={'label':label,'timedOut':False}
process=None
try:
    process=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    try:result['returnCode']=process.wait(timeout=float(seconds))
    except subprocess.TimeoutExpired:
        result['timedOut']=True
        # Only the process group created immediately above is targeted. sudo
        # children may run as root, so kill that disposable guest group as root.
        try:subprocess.run(['sudo','-n','/bin/kill','-KILL','--','-'+str(process.pid)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3)
        except (subprocess.TimeoutExpired,OSError):pass
        try:result['returnCode']=process.wait(timeout=2)
        except subprocess.TimeoutExpired:result['returnCode']=None
except OSError as error:result['errorType']=type(error).__name__
result['elapsed']=round(time.monotonic()-started,2)
with Path(path).open('a') as f:f.write(json.dumps(result)+'\n')
print('[update-runtime] guest command '+json.dumps(result),flush=True)
sys.exit(0 if result.get('returnCode')==0 and not result['timedOut'] else 1)
PYBOUND
}
ym_cleanup() {
  # Remove test executables before any potentially slow guest system cleanup.
  rm -f "$ym_evidence/UpdateRuntimeFixture" "$ym_evidence/UpdateRuntimeWindow"
  if [ -n "$ym_fixture_pid" ]; then kill "$ym_fixture_pid" 2>/dev/null || true; fi
  for ym_pid in $ym_window_pids; do kill "$ym_pid" 2>/dev/null || true; done
  ym_stop_server || true
  if [ -f "$ym_temporary/ca.crt" ]; then
    ym_bounded_guest_command remove-test-trust 10 sudo -n security remove-trusted-cert -d "$ym_temporary/ca.crt" || true
    ym_bounded_guest_command remove-test-certificate 10 sudo -n security delete-certificate -c "$ym_ca_name" /Library/Keychains/System.keychain || true
  fi
  if [ -f "$ym_temporary/codesign/codesign.crt" ]; then
    ym_bounded_guest_command remove-fixture-code-trust 10 sudo -n security remove-trusted-cert -d "$ym_temporary/codesign/codesign.crt" || true
    if ym_code_fingerprint="$(python3 - "$ym_temporary/codesign/identity.json" <<'PYFINGERPRINT'
import json,re,sys
try:
    with open(sys.argv[1]) as f:value=json.load(f)['fingerprint']
    if not isinstance(value,str) or not re.fullmatch(r'[A-Fa-f0-9]{40}',value):raise ValueError()
except (OSError,ValueError,KeyError):sys.exit(1)
print(value)
PYFINGERPRINT
)"; then
      ym_bounded_guest_command remove-fixture-code-certificate 10 sudo -n security delete-certificate \
        -Z "$ym_code_fingerprint" /Library/Keychains/System.keychain || true
    fi
  fi
  if [ -f "$ym_temporary/codesign/original-search-list.json" ]; then
    ym_bounded_guest_command restore-fixture-keychain-search-list 10 python3 \
      "$ym_root/scripts/update-runtime-guest-permissions.py" restore-search-list "$ym_temporary/codesign" || true
  fi
  if [ -f "$ym_temporary/codesign/identity.keychain-db" ]; then
    ym_bounded_guest_command remove-fixture-keychain 10 security delete-keychain "$ym_temporary/codesign/identity.keychain-db" || true
  fi
  rm -rf "$ym_temporary"
}
trap ym_cleanup EXIT
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -sha256 \
  -subj "/CN=$ym_ca_name" -keyout "$ym_temporary/ca.key" -out "$ym_temporary/ca.crt" \
  > "$ym_evidence/certificate-setup.log" 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=localhost \
  -keyout "$ym_temporary/server.key" -out "$ym_temporary/server.csr" \
  >> "$ym_evidence/certificate-setup.log" 2>&1
cat > "$ym_temporary/server.ext" <<'EXT'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -days 1 -sha256 -in "$ym_temporary/server.csr" \
  -CA "$ym_temporary/ca.crt" -CAkey "$ym_temporary/ca.key" -CAcreateserial \
  -extfile "$ym_temporary/server.ext" -out "$ym_temporary/server.crt" \
  >> "$ym_evidence/certificate-setup.log" 2>&1
ym_bounded_guest_command add-test-trust 30 sudo -n security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ym_temporary/ca.crt"
python3 "$ym_root/scripts/update-runtime-guest-permissions.py" setup "$ym_temporary/codesign"

cat > "$ym_temporary/key.swift" <<'SWIFT'
import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
SWIFT
xcrun swift "$ym_temporary/key.swift" "$ym_temporary/seed" "$ym_temporary/public"
chmod 600 "$ym_temporary/seed"
ym_public="$(cat "$ym_temporary/public")"

cat > "$ym_temporary/serve.py" <<'PY'
import sys,time,os,faulthandler
faulthandler.enable();faulthandler.dump_traceback_later(10,repeat=False)
print('server-process-started',os.getpid(),flush=True)
import http.server,ssl,socketserver
from pathlib import Path
print('server-imports-complete',flush=True)
class Handler(http.server.SimpleHTTPRequestHandler):
    def copyfile(self, source, output):
        try:
            while chunk := source.read(64 * 1024):
                output.write(chunk)
                output.flush()
                if self.path.endswith('.zip'): time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError): pass
class LocalFixtureServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # This loopback-only fixture has a fixed TLS hostname. HTTPServer's
        # reverse-DNS lookup is unnecessary and can stall disposable runners.
        socketserver.TCPServer.server_bind(self)
        self.server_name='localhost'
        self.server_port=self.server_address[1]
print('server-bind-start',flush=True)
server = LocalFixtureServer(('127.0.0.1', 0), Handler)
print('server-bind-complete',flush=True)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
Path(sys.argv[3]).write_text(str(server.server_port))
faulthandler.cancel_dump_traceback_later()
print('server-ready',flush=True)
server.serve_forever()
PY

ym_sign_bundle() {
  python3 "$ym_root/scripts/update-runtime-guest-permissions.py" sign "$ym_temporary/codesign" "$1"
}
mkdir -p "$ym_temporary/served"
  (
    cd "$ym_temporary/served"
    exec python3 -u "$ym_temporary/serve.py" "$ym_temporary/server.crt" "$ym_temporary/server.key" "$ym_temporary/port"
  ) > "$ym_evidence/server.log" 2>&1 &
  ym_server_pid=$!
  if ! ym_port="$(python3 - "$ym_temporary/port" "$ym_server_pid" "$ym_evidence/server-readiness.json" <<'PYREADY'
from pathlib import Path
import json,subprocess,sys,time
path,pid,out=Path(sys.argv[1]),int(sys.argv[2]),Path(sys.argv[3]);started=time.monotonic();deadline=started+30
port=None;reason='timeout';observations=[]
while time.monotonic()<deadline:
    try:
        process=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True,timeout=2)
        state=process.stdout.strip();alive=process.returncode==0 and bool(state) and not state.startswith('Z')
    except subprocess.TimeoutExpired:state='ps-timeout';alive=True
    observations.append({'elapsed':round(time.monotonic()-started,2),'pid':pid,'state':state,'alive':alive})
    if path.exists():
        try:candidate=int(path.read_text().strip())
        except ValueError:candidate=0
        if alive and 0<candidate<65536:port=candidate;reason='ready';break
    if not alive:reason='server-exited';break
    time.sleep(.2)
out.write_text(json.dumps({'reason':reason,'port':port,'observations':observations},indent=2)+'\n')
print('[update-runtime] server readiness '+json.dumps({'reason':reason,'elapsed':round(time.monotonic()-started,2),'pid':pid,'state':state}),file=sys.stderr,flush=True)
if port:print(port)
sys.exit(0 if port else 1)
PYREADY
)"; then
    printf '[update-runtime] shared server failed readiness; inspect server.log and server-readiness.json\n' >&2
    exit 1
  fi

ym_result=0
for ym_case in "${ym_cases[@]}"; do
  printf '[update-runtime] %s prepare\n' "$ym_case"
  ym_case_evidence="$ym_evidence/$ym_case"
  ym_case_root="$ym_temporary/$ym_case"
  ym_case_public="$ym_temporary/served/$ym_case"
  mkdir -p "$ym_case_evidence" "$ym_case_public" "$ym_case_root/install"
  ym_feed="https://localhost:$ym_port/$ym_case/appcast.xml"
  ym_work_pid=0
  ym_probe_pid=0
  if [ "$ym_case" = occupied ]; then
    for ym_role in work-window physical-probe; do
      ym_window_app="$ym_case_root/$ym_role.app"
      mkdir -p "$ym_window_app/Contents/MacOS"
      cp "$ym_evidence/UpdateRuntimeWindow" "$ym_window_app/Contents/MacOS/UpdateRuntimeWindow"
      python3 - "$ym_window_app/Contents/Info.plist" "$ym_role" "$ym_case_evidence/$ym_role.jsonl" <<'PYWINDOW'
import plistlib,sys
path,role,sample=sys.argv[1:]
with open(path,'wb') as f:plistlib.dump({'CFBundleIdentifier':'dev.chekusu.yomado.fixture.window.'+role,
 'CFBundleExecutable':'UpdateRuntimeWindow','CFBundleName':role,'CFBundlePackageType':'APPL',
 'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','NSPrincipalClass':'NSApplication',
 'LSMinimumSystemVersion':'14.0','YMHostedDisposableFixture':True,'YMFixtureWindowRole':role,'YMFixtureSamplePath':sample},f)
PYWINDOW
      codesign --force --sign - "$ym_window_app" >> "$ym_case_evidence/signatures.log" 2>&1
      "$ym_window_app/Contents/MacOS/UpdateRuntimeWindow" > "$ym_case_evidence/$ym_role.stdout" 2> "$ym_case_evidence/$ym_role.stderr" &
      ym_window_pid=$!
      ym_window_pids="$ym_window_pids $ym_window_pid"
      if [ "$ym_role" = work-window ]; then ym_work_pid=$ym_window_pid; else ym_probe_pid=$ym_window_pid; fi
      for ym_wait in $(seq 1 50); do [ -s "$ym_case_evidence/$ym_role.jsonl" ] && break; sleep .1; done
    done
  fi
  for ym_build in 1 2; do
    ym_app="$ym_case_root/build-$ym_build/YomadoUpdateFixture.app"
    mkdir -p "$ym_app/Contents/MacOS" "$ym_app/Contents/Frameworks"
    cp "$ym_evidence/UpdateRuntimeFixture" "$ym_app/Contents/MacOS/UpdateRuntimeFixture"
    ditto --norsrc --noextattr "$ym_sparkle/Sparkle.framework" "$ym_app/Contents/Frameworks/Sparkle.framework"
    python3 - "$ym_app/Contents/Info.plist" "$ym_build" "$ym_case" "$ym_public" "$ym_feed" "$ym_case_evidence" "$ym_work_pid" "$ym_probe_pid" <<'PY'
import plistlib,sys
p,build,scenario,key,feed,evidence,workpid,probepid=sys.argv[1:]
info={'CFBundleIdentifier':'dev.chekusu.yomado.fixture.'+scenario,
      'CFBundleExecutable':'UpdateRuntimeFixture','CFBundleName':'YomadoUpdateFixture',
      'CFBundlePackageType':'APPL','CFBundleVersion':build,'CFBundleShortVersionString':'1.'+str(int(build)-1),
      'LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,
      'SUPublicEDKey':key,'SUFeedURL':feed,'SUEnableAutomaticChecks':scenario=='automatic','SUAutomaticallyUpdate':False,
      'SURequireSignedFeed':True,'SUVerifyUpdateBeforeExtraction':True,'SUSendProfileInfo':False,
      'YMFixtureWorkPID':int(workpid),'YMFixtureProbePID':int(probepid),
      'YMHostedDisposableFixture':True,'YMFixtureEvidenceDirectory':evidence,'YMFixtureScenario':scenario}
with open(p,'wb') as f:plistlib.dump(info,f)
PY
    ym_sign_bundle "$ym_app" >> "$ym_case_evidence/signatures.log" 2>&1
  done
  if [ "$ym_case" = occupied ]; then
    python3 "$ym_root/scripts/update-runtime-guest-permissions.py" grant "$ym_temporary/codesign" \
      "$ym_case_root/build-1/YomadoUpdateFixture.app" "$ym_case_root/build-2/YomadoUpdateFixture.app" \
      "$ym_case_evidence/guest-permission-setup.json"
  fi
  ditto -c -k --norsrc --noextattr --keepParent "$ym_case_root/build-2/YomadoUpdateFixture.app" "$ym_case_public/update.zip"
  ym_signature="$("$ym_sparkle/bin/sign_update" --ed-key-file "$ym_temporary/seed" -p "$ym_case_public/update.zip")"
  python3 - "$ym_case_public" "$ym_port" "$ym_signature" "$ym_case" <<'PY'
from pathlib import Path
import sys,xml.etree.ElementTree as E
d,port,signature,case=Path(sys.argv[1]),sys.argv[2],sys.argv[3],sys.argv[4]
ns='http://www.andymatuschak.org/xml-namespaces/sparkle';E.register_namespace('sparkle',ns)
rss=E.Element('rss',{'version':'2.0'});c=E.SubElement(rss,'channel');E.SubElement(c,'title').text='Isolated update fixture'
E.SubElement(c,'link').text='https://localhost:'+port+'/'+case+'/';E.SubElement(c,'description').text='Disposable guest only'
i=E.SubElement(c,'item');E.SubElement(i,'title').text='Fixture 1.1';E.SubElement(i,'{'+ns+'}version').text='2'
E.SubElement(i,'{'+ns+'}shortVersionString').text='1.1';E.SubElement(i,'{'+ns+'}minimumSystemVersion').text='14.0'
E.SubElement(i,'enclosure',{'url':'https://localhost:'+port+'/'+case+'/update.zip','type':'application/octet-stream',
  'length':str((d/'update.zip').stat().st_size),'{'+ns+'}edSignature':signature})
E.ElementTree(rss).write(d/'appcast.xml',encoding='utf-8',xml_declaration=True)
PY
  "$ym_sparkle/bin/sign_update" --ed-key-file "$ym_temporary/seed" "$ym_case_public/appcast.xml" > "$ym_case_evidence/feed-sign.log"
  "$ym_sparkle/bin/sign_update" --ed-key-file "$ym_temporary/seed" --verify "$ym_case_public/appcast.xml" >> "$ym_case_evidence/feed-sign.log"
  "$ym_sparkle/bin/sign_update" --ed-key-file "$ym_temporary/seed" --verify "$ym_case_public/update.zip" "$ym_signature" >> "$ym_case_evidence/feed-sign.log"
  if [ "$ym_case" = tampered-feed ]; then
    python3 - "$ym_case_public/appcast.xml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_bytes(p.read_bytes().replace(b'Isolated update fixture',b'Altered update fixture'))
PY
  elif [ "$ym_case" = tampered-archive ]; then
    python3 - "$ym_case_public/update.zip" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);data=bytearray(p.read_bytes());data[len(data)//2]^=1;p.write_bytes(data)
PY
  fi
  ditto --norsrc --noextattr "$ym_case_root/build-1/YomadoUpdateFixture.app" "$ym_case_root/install/YomadoUpdateFixture.app"
  if [ "$ym_case" = offline ]; then ym_stop_server; fi
  printf '[update-runtime] %s launch\n' "$ym_case"
  "$ym_case_root/install/YomadoUpdateFixture.app/Contents/MacOS/UpdateRuntimeFixture" > "$ym_case_evidence/app.stdout" 2> "$ym_case_evidence/app.stderr" &
  ym_fixture_pid=$!
  python3 - "$ym_case_evidence/events.jsonl" "$ym_case" "$ym_fixture_pid" "$ym_case_root/install/YomadoUpdateFixture.app/Contents/MacOS/UpdateRuntimeFixture" <<'PY'
from pathlib import Path
import json,subprocess,sys,time
p,case,initial_pid,executable=Path(sys.argv[1]),sys.argv[2],int(sys.argv[3]),sys.argv[4]
started=time.monotonic();end=started+150;terminal=None;empty_since=None;next_summary=started;reason='timeout';observations=[]
def live(pid):
    try:
        result=subprocess.run(['ps','-p',str(pid),'-o','stat=','-o','command='],capture_output=True,text=True,timeout=3)
        parts=result.stdout.strip().split(None,1)
        return result.returncode==0 and len(parts)==2 and not parts[0].startswith('Z') and (parts[1]==executable or parts[1].startswith(executable+' '))
    except (subprocess.TimeoutExpired,OSError):return False
while time.monotonic()<end:
    records=[]
    if p.exists():
        for line in p.read_text().splitlines():
            try:records.append(json.loads(line))
            except ValueError:pass
    seen={r['event'] for r in records};last=records[-1] if records else {}
    failure=seen.intersection({'start-failed','fixture-failure','recovery-failed','updater-error'})
    done=bool(failure) or 'updated-and-recovered' in seen or (case=='cancel' and 'cancel-requested' in seen)
    if done:
        reason=sorted(failure)[0] if failure else ('cancel-requested' if case=='cancel' else 'updated-and-recovered')
        terminal=terminal or time.monotonic()
        if time.monotonic()-terminal>=8:break
    if time.monotonic()>=next_summary:
        pids={initial_pid}|{r['pid'] for r in records if r['event']=='launched'}
        living={str(pid):live(pid) for pid in sorted(pids)}
        observation={'case':case,'elapsed':round(time.monotonic()-started,1),'event':last.get('event','none'),
                     'code':last.get('code',last.get('errorCode')),'status':last.get('status'),'pidsAlive':living}
        observations.append(observation);print(json.dumps(observation),flush=True);next_summary=time.monotonic()+15
        if any(living.values()):empty_since=None
        else:empty_since=empty_since or time.monotonic()
    if empty_since is not None and not done:
        # A successfully armed installer can temporarily leave no host process.
        # Give its relaunch time to start; a crash before installation needs no such delay.
        installing=any(r.get('authorized') or (r['event']=='termination-gate' and r.get('committed')) for r in records)
        if time.monotonic()-empty_since>=(45 if installing else 3):
            reason='no-host-after-relaunch-grace' if installing else 'host-exited-before-install';break
    time.sleep(.2)
report={'case':case,'reason':reason,'elapsed':round(time.monotonic()-started,2),'observations':observations}
p.with_name('wait-result.json').write_text(json.dumps(report,indent=2)+'\n')
print('[update-runtime] '+case+' observation completed: '+reason,flush=True)
PY
  python3 - "$ym_case_evidence/unified-fixture.log" <<'PYLOG'
from pathlib import Path
import subprocess,sys
predicate='process == "UpdateRuntimeFixture" OR subsystem == "org.sparkle-project.Sparkle" OR process == "Autoupdate" OR process == "Updater"'
try:
    result=subprocess.run(['/usr/bin/log','show','--last','4m','--style','compact','--predicate',predicate],capture_output=True,text=True,timeout=20)
    Path(sys.argv[1]).write_text(result.stdout+'\n'+result.stderr)
except subprocess.TimeoutExpired:
    Path(sys.argv[1]).write_text('Fixture-scoped unified log collection timed out.\n')
PYLOG
  screencapture -x "$ym_case_evidence/desktop.png" 2> "$ym_case_evidence/screenshot.log" || true
  python3 - "$ym_case_evidence/observation-end.json" "$ym_case_evidence/events.jsonl" \
    "$ym_case_root/install/YomadoUpdateFixture.app/Contents/MacOS/UpdateRuntimeFixture" <<'PYEND'
import json,subprocess,sys,time
from pathlib import Path
events=Path(sys.argv[2]);executable=sys.argv[3]
records=[json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
report={'time':time.time(),'pidsAlive':{}}
for pid in {r['pid'] for r in records if r['event']=='launched'}:
    try:
        result=subprocess.run(['ps','-p',str(pid),'-o','stat=','-o','command='],capture_output=True,text=True,timeout=3)
        parts=result.stdout.strip().split(None,1)
        alive=result.returncode==0 and len(parts)==2 and not parts[0].startswith('Z') and (parts[1]==executable or parts[1].startswith(executable+' '))
    except (subprocess.TimeoutExpired,OSError):alive=False
    report['pidsAlive'][str(pid)]=bool(alive)
Path(sys.argv[1]).write_text(json.dumps(report)+'\n')
PYEND
  # Stop only fixture PIDs recorded by this test, including the relaunched copy.
  python3 - "$ym_case_evidence/events.jsonl" "$ym_case_root/install/YomadoUpdateFixture.app/Contents/MacOS/UpdateRuntimeFixture" <<'PY'
from pathlib import Path
import json,os,signal,subprocess,sys
p=Path(sys.argv[1]);records=[json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []
for pid in {r['pid'] for r in records if r['event']=='launched'}:
    current=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
    if current.returncode or current.stdout.strip()!=sys.argv[2]:continue
    try:os.kill(pid,signal.SIGTERM)
    except ProcessLookupError:pass
PY
  ym_fixture_pid=""
  sleep 5
  python3 - "$ym_evidence/server.log" "$ym_case_evidence/server.log" "$ym_case" <<'PYCASELOG'
from pathlib import Path
import sys
source,target,case=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
lines=source.read_text().splitlines() if source.exists() else []
target.write_text('\n'.join(line for line in lines if ' /'+case+'/' in line)+'\n')
PYCASELOG
  if ! python3 - "$ym_case_evidence" "$ym_case_root/install/YomadoUpdateFixture.app" "$ym_case" <<'PY'
import json,plistlib,subprocess,sys
from pathlib import Path
d,app,case=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
events=[json.loads(x) for x in (d/'events.jsonl').read_text().splitlines()] if (d/'events.jsonl').exists() else []
seen={r['event'] for r in events};build=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleVersion']
errors=[r for r in events if r['event']=='updater-error'];old=[r for r in events if r['event']=='launched' and r['build']=='1']
new=[r for r in events if r['event']=='launched' and r['build']=='2'];log=(d/'server.log').read_text()
end_observation=json.loads((d/'observation-end.json').read_text())
checks={'old-launched':len(old)==1,'no-start-or-fixture-failure':not seen.intersection({'start-failed','fixture-failure'})}
if case in ('update','automatic','occupied'):
    checks.update({'installed-build2':build=='2','new-process':len(new)==1 and old and new[0]['pid']!=old[0]['pid'],
      'new-process-still-running':len(new)==1 and end_observation['pidsAlive'].get(str(new[0]['pid']),False),
      'workspace-prepared':any(r['event']=='workspace-prepared' and r['ready'] for r in events),
      'termination-committed':any(r['event']=='termination-gate' and r['committed'] for r in events),
      'recovered-after-install':any(r['event']=='updated-and-recovered' and r.get('journalConsumed') for r in events),'archive-requested':('GET /'+case+'/update.zip HTTP') in log,
      'no-updater-errors':not errors,
      'installed-signature-valid':subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True).returncode==0})
    if case=='automatic':
        checks['scheduled-automatically']=any(r['event']=='automatic-scheduler-armed' and r['enabled'] for r in events)
        checks['no-manual-check']='manual-check-requested' not in seen
        checks['background-download']=any(r['event']=='updater-state' and r.get('status')==2 and not r.get('userInitiated',True) for r in events)
    if case=='occupied':
        ready=[r for r in events if r['event']=='occupied-ready']
        verified=[r for r in events if r['event']=='occupied-verified']
        checks['occupied-prepared-once']=len(ready)==1 and len(ready[0]['profiles'])==1
        recreated=[r for r in events if r['event']=='occupied-recreate']
        checks['updated-process-retains-AX']=len(recreated)==1 and recreated[0].get('accessibilityTrusted') is True
        checks['occupied-verified-once']=len(verified)==1 and verified[0]['matches']
        if ready and verified:
            baseline=ready[0]; after=verified[0]
            checks['same-work-identity']=baseline['work']['identity']==after['currentWork']['identity']
            checks['same-work-frame']=baseline['work']['frame']==after['currentWork']['frame']
            checks['same-probe-identity-frame']=baseline['probe']==after['currentProbe']
            end=json.loads((d/'observation-end.json').read_text())['time']
            samples={role:[r for x in (d/(role+'.jsonl')).read_text().splitlines() if baseline['time'] <= (r:=json.loads(x))['time'] <= end]
                     for role in ('work-window','physical-probe')}
            for role,records in samples.items():
                expected=baseline['work' if role=='work-window' else 'probe']
                checks[role+'-same-process-window']=bool(records) and all(
                    r['pid']==expected['identity']['pid'] and r['windowID']==expected['identity']['windowID'] and r['onscreen'] for r in records)
                checks[role+'-continued-rendering']=len(records)>10 and records[-1]['counter']>records[0]['counter']+10
                stable=[r for r in records if r['time']>=after['time']+.5]
                checks[role+'-stable-after-recovery']=len(stable)>=5 and all(r['frame']==expected['frame'] for r in stable)
            checks['screenshots-captured']=all((d/name).is_file() and (d/name).stat().st_size>1000 for name in ('occupied-before.png','occupied-after.png'))
            checks['physical-probe-never-moved']=all(r['frame']==baseline['probe']['frame'] for r in samples['physical-probe'])
else:
    checks.update({'kept-build1':build=='1','never-relaunched-new':not new,
      'old-process-still-running':len(old)==1 and end_observation['pidsAlive'].get(str(old[0]['pid']),False),
      'never-authorized-install':not any(r.get('authorized') for r in events),'no-termination-commit':'termination-gate' not in seen})
    if case=='cancel':checks['cancelled-after-data']=('cancel-requested' in seen and any(r['event']=='updater-state' and r.get('status')==2 and r.get('progress',-1)>0 for r in events))
    elif case=='gate-veto':checks['explicit-veto']=('gate-veto' in seen and any(r['domain']=='fixture.workspace-busy' for r in errors))
    elif case=='offline':checks['network-error-observed']=bool(errors) and 'GET /' not in log
    else:
        checks['signature-rejection']=any(e['domain']=='SUSparkleErrorDomain' and e['code'] in (3001,3002) for r in errors for e in r.get('chain',[]))
        checks['archive-fetch-boundary']=(('GET /'+case+'/update.zip HTTP') in log) == (case=='tampered-archive')
report={'scenario':case,'checks':checks,'passed':all(checks.values()),'installedBuild':build,
        'scope':'Real updater with native recovery and one surviving window plus untouched physical probe.' if case=='occupied' else 'Real updater and native zero-owned-display journal. Temporary self-signed fixture certificate; not Developer ID/notarized acceptance.'}
(d/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report));sys.exit(0 if report['passed'] else 1)
PY
  then ym_result=1; fi
  for ym_pid in $ym_window_pids; do kill "$ym_pid" 2>/dev/null || true; done
  ym_window_pids=""
done
exit "$ym_result"
