# Direct PluginHost test: compile+run the real chat plugin, time it, verify window
import clr, os, time, re
DATA_DIR = os.path.join(os.environ['LOCALAPPDATA'], 'wgime-py')
dll = max((os.path.join(DATA_DIR, f) for f in os.listdir(DATA_DIR) if f.startswith('bridge.')), key=os.path.getmtime)
clr.AddReference(dll)
clr.AddReference('System.Windows.Forms')
from WgBridge import PluginHost
PluginHost.Start()
text = open(r'C:\Tools\wgime\plugins\chat.txt', encoding='utf-8').read()
m = re.search(r'(?s)\[csharp\]\s*(.*?)\[/csharp\]', text)
cs = m.group(1)
import hashlib
t0 = time.time()
err = PluginHost.CompileAndRun(cs, DATA_DIR, hashlib.md5(cs.encode('utf-8')).hexdigest()[:8])
print('err:', err)
print('compile+run took %.1fs' % (time.time() - t0))
time.sleep(6)
print('windows:')
import System.Windows.Forms as WF
for f in WF.Application.OpenForms:
    print(' -', f.Text, f.Visible, f.Bounds)
