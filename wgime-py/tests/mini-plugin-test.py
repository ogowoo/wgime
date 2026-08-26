# Minimal PluginHost sanity (fixed C# source, no real newline in string)
import clr, os, time
DATA_DIR = os.path.join(os.environ['LOCALAPPDATA'], 'wgime-py')
dll = max((os.path.join(DATA_DIR, f) for f in os.listdir(DATA_DIR) if f.startswith('bridge.')), key=os.path.getmtime)
clr.AddReference(dll)
clr.AddReference('System.Windows.Forms')
from WgBridge import PluginHost
PluginHost.Start()
cs = ('using System; using System.Windows.Forms;'
      'public class MiniPlugin {'
      '  public static void Run() {'
      '    var f = new Form { Text = "MiniOK", TopMost = true };'
      '    f.Shown += delegate { System.IO.File.AppendAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "wgpy-plugin-err.txt"), "SHOWN\\r\\n"); };'
      '    f.Show();'
      '  }'
      '}')
import hashlib
err = PluginHost.CompileAndRun(cs, DATA_DIR, hashlib.md5(cs.encode('utf-8')).hexdigest()[:8])
print('err:', repr(err))
time.sleep(3)
import System.Windows.Forms as WF
print('count:', WF.Application.OpenForms.Count)
for f in WF.Application.OpenForms:
    print(' -', f.Text, f.Visible)
