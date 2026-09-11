# -*- coding: utf-8 -*-
"""WGIME pure-Python plugin: clipboard translator."""

CODE = "fy"
NAME = "剪贴板翻译"
DESC = "双击 Ctrl+C 自动读取剪贴板并翻译，支持多翻译通道与格式保留"
VERSION = "2.2.0"
AUTHOR = "Walt Liang"
PERM = "network,run"

import ctypes
from ctypes import wintypes
import html, json, queue, re, sys, threading, time
import urllib.parse, urllib.request
from pathlib import Path
import tkinter as tk
from tkinter import ttk, messagebox

APP = "wgtranslate"
LOG = Path.home()/"AppData"/"Local"/APP/"wgtranslate_error.log"
DOUBLE_COPY_MS = 700
CHUNK_BYTES = 430

LANGUAGES = {
    "自动判断":"auto", "简体中文":"zh-CN", "繁体中文":"zh-TW", "英语":"en",
    "日语":"ja", "韩语":"ko", "法语":"fr", "德语":"de", "西班牙语":"es",
    "葡萄牙语":"pt", "意大利语":"it", "俄语":"ru", "乌克兰语":"uk",
    "丹麦语":"da", "荷兰语":"nl", "瑞典语":"sv", "挪威语":"no",
    "芬兰语":"fi", "波兰语":"pl", "捷克语":"cs", "匈牙利语":"hu",
    "罗马尼亚语":"ro", "保加利亚语":"bg", "希腊语":"el", "土耳其语":"tr", "阿拉伯语":"ar",
    "希伯来语":"he", "印地语":"hi", "泰语":"th", "越南语":"vi",
    "印度尼西亚语":"id", "马来语":"ms"
}
PROVIDERS = ("自动容错", "Google 网页翻译", "MyMemory", "Lingva 公共实例",
             "SimplyTranslate 公共实例", "LibreTranslate 本机", "Argos 离线")
LINGVA = ["https://translate.plausibility.cloud", "https://translate.projectsegfau.lt", "https://lingva.ml"]
SIMPLY = ["https://simplytranslate.org", "https://st.tokhmi.xyz"]
LIBRE = "http://127.0.0.1:5000"


def log_error(x):
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as f: f.write(time.strftime("%F %T ")+str(x)+"\n")
    except Exception: pass


def fetch_json(url, payload=None, timeout=22):
    headers={"User-Agent":"Mozilla/5.0 wgtranslate/2.1"}; body=None
    if payload is not None:
        body=json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"]="application/json; charset=utf-8"
    req=urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def chunks(text, limit=CHUNK_BYTES):
    out=[]; buf=""
    for unit in re.split(r"(?<=[。！？.!?；;\n])", text):
        if len((buf+unit).encode()) <= limit: buf += unit; continue
        if buf: out.append(buf); buf=""
        for ch in unit:
            if len((buf+ch).encode()) > limit:
                if buf: out.append(buf)
                buf=ch
            else: buf += ch
    if buf: out.append(buf)
    return out


def layout_units(text):
    """Split text into translatable units while preserving visual layout.

    Blank lines, indentation, bullet/number markers, trailing spaces, and original
    line endings are copied verbatim. Only each line's textual body is translated.
    """
    units=[]
    for raw in text.splitlines(keepends=True):
        body=raw.rstrip("\r\n")
        ending=raw[len(body):]
        if not body.strip():
            units.append((body, "", "", ending, False))
            continue
        # Preserve indentation plus common list/outline markers.
        match=re.match(r"^(\s*(?:(?:[-*+•▪◦‣])|(?:\(?\d+[.)])|(?:[A-Za-z][.)])|(?:\[[ xX]\]))?\s*)(.*?)(\s*)$", body)
        prefix, core, suffix=match.group(1),match.group(2),match.group(3)
        units.append((prefix,core,suffix,ending,True))
    # splitlines() returns nothing for an empty string, and omits a final empty unit.
    if not units and text=="": return []
    return units


def detect_source(text):
    """Detect the dominant script instead of treating any Han character as Chinese."""
    counts={"han":0,"latin":0,"kana":0,"hangul":0,"cyrillic":0,
            "arabic":0,"hebrew":0,"thai":0}
    for ch in text:
        u=ord(ch)
        if 0x4E00 <= u <= 0x9FFF or 0x3400 <= u <= 0x4DBF:
            counts["han"] += 1
        elif 0x3040 <= u <= 0x30FF or 0x31F0 <= u <= 0x31FF:
            counts["kana"] += 1
        elif 0xAC00 <= u <= 0xD7AF:
            counts["hangul"] += 1
        elif 0x0041 <= u <= 0x005A or 0x0061 <= u <= 0x007A or 0x00C0 <= u <= 0x024F:
            counts["latin"] += 1
        elif 0x0400 <= u <= 0x052F:
            counts["cyrillic"] += 1
        elif 0x0600 <= u <= 0x06FF:
            counts["arabic"] += 1
        elif 0x0590 <= u <= 0x05FF:
            counts["hebrew"] += 1
        elif 0x0E00 <= u <= 0x0E7F:
            counts["thai"] += 1

    # Japanese commonly mixes kana and Han, so kana takes priority.
    if counts["kana"] >= 2: return "ja"
    if counts["hangul"] >= 2: return "ko"
    if counts["cyrillic"] >= 2 and counts["cyrillic"] > counts["latin"]: return "ru"
    if counts["arabic"] >= 2 and counts["arabic"] > counts["latin"]: return "ar"
    if counts["hebrew"] >= 2 and counts["hebrew"] > counts["latin"]: return "he"
    if counts["thai"] >= 2 and counts["thai"] > counts["latin"]: return "th"

    # Chinese must be dominant. One or two Chinese characters inside an English
    # paragraph no longer switch the whole translation direction to Chinese.
    han,latin=counts["han"],counts["latin"]
    meaningful=han+latin
    if han >= 2 and meaningful and (han/meaningful >= 0.35 or (han >= 4 and han > latin)):
        return "zh-CN"
    return "en"


def pair(text):
    source=detect_source(text)
    target="en" if source.startswith("zh") else "zh-CN"
    return source,target


def code(c, family):
    maps={"lingva":{"zh-CN":"zh","zh-TW":"zh_HANT"},
          "libre":{"zh-CN":"zh","zh-TW":"zt"},
          "argos":{"zh-CN":"zh","zh-TW":"zh"}}
    return maps.get(family,{}).get(c,c)


def google(text, src, dst):
    q=urllib.parse.urlencode({"client":"gtx","sl":src,"tl":dst,"dt":"t","q":text})
    data=fetch_json("https://translate.googleapis.com/translate_a/single?"+q)
    value="".join(x[0] for x in data[0] if x and x[0])
    if not value: raise RuntimeError("Google 没有返回译文")
    return value


def mymemory(text, src, dst):
    q=urllib.parse.urlencode({"q":text,"langpair":f"{src}|{dst}","mt":"1"})
    data=fetch_json("https://api.mymemory.translated.net/get?"+q)
    if str(data.get("responseStatus",200)) != "200": raise RuntimeError(str(data.get("responseDetails","请求失败")))
    value=data.get("responseData",{}).get("translatedText")
    if value is None: raise RuntimeError("MyMemory 没有返回译文")
    return html.unescape(str(value))


def lingva(text, src, dst):
    src,dst=code(src,"lingva"),code(dst,"lingva"); errors=[]
    for host in LINGVA:
        try:
            u=host+"/api/v1/{}/{}/{}".format(src,dst,urllib.parse.quote(text,safe=""))
            value=fetch_json(u).get("translation")
            if value: return html.unescape(str(value))
            raise RuntimeError("响应缺少 translation")
        except Exception as e: errors.append(str(e))
    raise RuntimeError("Lingva 不可用："+" | ".join(errors))


def simply(text, src, dst):
    src,dst=code(src,"libre"),code(dst,"libre"); errors=[]
    for host in SIMPLY:
        try:
            q=urllib.parse.urlencode({"engine":"google","from":src,"to":dst,"text":text})
            data=fetch_json(host+"/api/translate/?"+q)
            value=data.get("translated-text") or data.get("translated_text") or data.get("translation")
            if value: return html.unescape(str(value))
            raise RuntimeError("响应缺少译文")
        except Exception as e: errors.append(str(e))
    raise RuntimeError("SimplyTranslate 不可用："+" | ".join(errors))


def libre(text, src, dst):
    data=fetch_json(LIBRE+"/translate", {"q":text,"source":code(src,"libre"),
                    "target":code(dst,"libre"),"format":"text"},30)
    value=data.get("translatedText")
    if value is None: raise RuntimeError(str(data.get("error","LibreTranslate 没有返回译文")))
    return html.unescape(str(value))


def argos(text, src, dst):
    try: import argostranslate.translate
    except ImportError as e: raise RuntimeError("请先运行 pip install argostranslate") from e
    value=argostranslate.translate.translate(text,code(src,"argos"),code(dst,"argos"))
    if not value or value == text: raise RuntimeError("Argos 缺少对应语言模型")
    return value

FUNCS={"Google 网页翻译":google,"MyMemory":mymemory,"Lingva 公共实例":lingva,
       "SimplyTranslate 公共实例":simply,"LibreTranslate 本机":libre,"Argos 离线":argos}
ORDER=("Google 网页翻译","MyMemory","Lingva 公共实例","SimplyTranslate 公共实例","LibreTranslate 本机","Argos 离线")


def translate_piece(text,src,dst,provider):
    if provider != "自动容错": return FUNCS[provider](text,src,dst),provider
    errors=[]
    for name in ORDER:
        try: return FUNCS[name](text,src,dst),name
        except Exception as e: errors.append(f"{name}: {e}")
    raise RuntimeError("所有通道均失败："+" | ".join(errors))


class Hook:
    WH_KEYBOARD_LL=13; WM_KEYDOWN=0x100; WM_SYSKEYDOWN=0x104; WM_QUIT=0x12; VK_C=0x43; VK_CTRL=0x11
    class K(ctypes.Structure):
        _fields_=[("vkCode",wintypes.DWORD),("scanCode",wintypes.DWORD),("flags",wintypes.DWORD),
                  ("time",wintypes.DWORD),("extra",wintypes.WPARAM)]
    def __init__(self,fire):
        self.fire=fire; self.hook=None; self.proc=None; self.thread_id=0; self.last=0.0
        self.ready=threading.Event(); self.error=None
    def start(self):
        threading.Thread(target=self._run,daemon=True).start(); self.ready.wait(2)
        if self.error: raise RuntimeError(self.error)
    def _run(self):
        try:
            u=ctypes.WinDLL("user32",use_last_error=True); k=ctypes.WinDLL("kernel32",use_last_error=True)
            PROC=ctypes.WINFUNCTYPE(wintypes.LPARAM,ctypes.c_int,wintypes.WPARAM,wintypes.LPARAM)
            u.SetWindowsHookExW.argtypes=[ctypes.c_int,PROC,wintypes.HINSTANCE,wintypes.DWORD]; u.SetWindowsHookExW.restype=wintypes.HHOOK
            u.CallNextHookEx.argtypes=[wintypes.HHOOK,ctypes.c_int,wintypes.WPARAM,wintypes.LPARAM]; u.CallNextHookEx.restype=wintypes.LPARAM
            u.UnhookWindowsHookEx.argtypes=[wintypes.HHOOK]; u.UnhookWindowsHookEx.restype=wintypes.BOOL
            u.GetAsyncKeyState.argtypes=[ctypes.c_int]; u.GetAsyncKeyState.restype=wintypes.SHORT
            k.GetCurrentThreadId.restype=wintypes.DWORD; self.thread_id=k.GetCurrentThreadId()
            def cb(n,w,l):
                if n>=0 and w in (self.WM_KEYDOWN,self.WM_SYSKEYDOWN):
                    key=ctypes.cast(l,ctypes.POINTER(self.K)).contents
                    if key.vkCode==self.VK_C and u.GetAsyncKeyState(self.VK_CTRL)&0x8000:
                        now=time.monotonic()
                        if 0 < (now-self.last)*1000 <= DOUBLE_COPY_MS: self.last=0; self.fire()
                        else: self.last=now
                return u.CallNextHookEx(self.hook,n,w,l)
            self.proc=PROC(cb); ctypes.set_last_error(0)
            self.hook=u.SetWindowsHookExW(self.WH_KEYBOARD_LL,self.proc,None,0)
            if not self.hook: raise RuntimeError(f"键盘钩子失败：{ctypes.get_last_error()}")
            self.ready.set(); msg=wintypes.MSG()
            while u.GetMessageW(ctypes.byref(msg),None,0,0)>0: u.TranslateMessage(ctypes.byref(msg)); u.DispatchMessageW(ctypes.byref(msg))
            u.UnhookWindowsHookEx(self.hook)
        except Exception as e: self.error=str(e); self.ready.set(); log_error(repr(e))
    def stop(self):
        if self.thread_id: ctypes.windll.user32.PostThreadMessageW(self.thread_id,self.WM_QUIT,0,0)


class ModernScrollbar(tk.Canvas):
    """Slim, borderless scrollbar with a rounded-looking thumb."""
    def __init__(self, master, command=None, width=10, **kwargs):
        super().__init__(master, width=width, highlightthickness=0, bd=0,
                         bg="#ffffff", cursor="arrow", **kwargs)
        self.command = command
        self.first = 0.0
        self.last = 1.0
        self.drag_start_y = None
        self.drag_start_first = 0.0
        self.thumb_color = "#c4cedd"
        self.thumb_hover = "#9eacc1"
        self.current_color = self.thumb_color
        self.bind("<Configure>", lambda e: self._draw())
        self.bind("<Button-1>", self._press)
        self.bind("<B1-Motion>", self._drag)
        self.bind("<ButtonRelease-1>", self._release)
        self.bind("<Motion>", self._motion)
        self.bind("<Leave>", self._leave)

    def set(self, first, last):
        self.first, self.last = float(first), float(last)
        self._draw()

    def _geometry(self):
        h = max(1, self.winfo_height())
        pad = 2
        track = max(1, h - pad * 2)
        top = pad + int(track * self.first)
        bottom = pad + int(track * self.last)
        minimum = 28
        if bottom - top < minimum:
            center = (top + bottom) // 2
            top = max(pad, center - minimum // 2)
            bottom = min(h - pad, top + minimum)
            top = max(pad, bottom - minimum)
        return pad, top, max(pad + 1, self.winfo_width() - pad), bottom

    def _draw(self):
        self.delete("all")
        if self.last - self.first >= 0.999:
            return
        x1, y1, x2, y2 = self._geometry()
        radius = max(2, (x2 - x1) // 2)
        self.create_rectangle(x1, y1 + radius, x2, y2 - radius,
                              fill=self.current_color, outline="")
        self.create_oval(x1, y1, x2, y1 + radius * 2,
                         fill=self.current_color, outline="")
        self.create_oval(x1, y2 - radius * 2, x2, y2,
                         fill=self.current_color, outline="")

    def _inside_thumb(self, y):
        _, top, _, bottom = self._geometry()
        return top <= y <= bottom

    def _press(self, event):
        if self._inside_thumb(event.y):
            self.drag_start_y = event.y
            self.drag_start_first = self.first
        elif self.command:
            self.command("scroll", -1 if event.y < self._geometry()[1] else 1, "pages")

    def _drag(self, event):
        if self.drag_start_y is None or not self.command:
            return
        track = max(1, self.winfo_height() - 4)
        visible = max(0.0001, self.last - self.first)
        movable = max(0.0001, 1.0 - visible)
        delta = (event.y - self.drag_start_y) / track
        position = min(movable, max(0.0, self.drag_start_first + delta))
        self.command("moveto", position)

    def _release(self, _event):
        self.drag_start_y = None

    def _motion(self, event):
        color = self.thumb_hover if self._inside_thumb(event.y) else self.thumb_color
        if color != self.current_color:
            self.current_color = color
            self._draw()

    def _leave(self, _event):
        self.current_color = self.thumb_color
        self._draw()


class App:
    BG="#f4f7fb"; CARD="#ffffff"; TEXT="#172033"; MUTED="#667085"; BORDER="#d9e1ec"; BLUE="#3578e5"
    def __init__(self,root):
        self.root=root; self.events=queue.Queue(); self.busy=False
        root.title(APP); root.geometry("860x600"); root.minsize(740,540); root.configure(bg=self.BG)
        root.protocol("WM_DELETE_WINDOW",self.quit); self.build()
        self.hook=Hook(lambda:self.events.put(("clip",None)))
        try:self.hook.start()
        except Exception as e:messagebox.showwarning(APP,str(e))
        root.after(80,self.poll)
    def btn(self,parent,text,cmd,blue=False,width=10):
        return tk.Button(parent,text=text,command=cmd,width=width,relief="flat",bd=0,cursor="hand2",pady=6,
                         font=("Segoe UI Semibold",9),bg=self.BLUE if blue else "#e9eef5",
                         fg="white" if blue else self.TEXT,activebackground="#2468d2" if blue else "#dde5ef")
    def build(self):
        st=ttk.Style(); st.theme_use("clam"); st.configure("TCombobox",fieldbackground=self.CARD,foreground=self.TEXT,background=self.CARD,bordercolor=self.BORDER,padding=(8,6))
        top=tk.Frame(self.root,bg=self.BG); top.pack(fill="x",padx=20,pady=(16,10))
        tk.Label(top,text=APP,bg=self.BG,fg=self.TEXT,font=("Segoe UI Semibold",18)).pack(side="left")
        tk.Label(top,text="Ctrl + C + C",bg="#e9efff",fg=self.BLUE,padx=12,pady=6,font=("Segoe UI Semibold",9)).pack(side="right")
        bar=tk.Frame(self.root,bg=self.CARD,highlightbackground=self.BORDER,highlightthickness=1,padx=12,pady=10); bar.pack(fill="x",padx=20,pady=(0,10))
        self.src=tk.StringVar(value="自动判断"); self.dst=tk.StringVar(value="简体中文"); self.provider=tk.StringVar(value="自动容错")
        ttk.Combobox(bar,textvariable=self.src,state="readonly",values=list(LANGUAGES),width=13).pack(side="left")
        tk.Label(bar,text="→",bg=self.CARD,fg=self.MUTED,padx=8).pack(side="left")
        ttk.Combobox(bar,textvariable=self.dst,state="readonly",values=[x for x in LANGUAGES if x!="自动判断"],width=13).pack(side="left")
        ttk.Combobox(bar,textvariable=self.provider,state="readonly",values=PROVIDERS,width=22).pack(side="left",padx=(10,0))
        self.keep_layout=tk.BooleanVar(value=True)
        tk.Checkbutton(bar,text="保留格式",variable=self.keep_layout,bg=self.CARD,fg=self.TEXT,
                       activebackground=self.CARD,activeforeground=self.TEXT,selectcolor=self.CARD,
                       font=("Segoe UI",9),bd=0,highlightthickness=0).pack(side="left",padx=(10,0))
        self.go=self.btn(bar,"翻译",self.start,True,8); self.go.pack(side="right")

        # Footer is packed before the expandable text area, guaranteeing visibility.
        foot=tk.Frame(self.root,bg=self.BG,height=48); foot.pack(side="bottom",fill="x",padx=20,pady=(8,12)); foot.pack_propagate(False)
        self.copy=self.btn(foot,"复制译文",self.copy_result); self.copy.pack(side="left",pady=6)
        self.clear=self.btn(foot,"清空内容",self.clear_content); self.clear.pack(side="left",padx=(8,0),pady=6)
        self.status=tk.StringVar(value="就绪 · 英文转中文，中文转英文")
        tk.Label(foot,textvariable=self.status,bg=self.BG,fg=self.MUTED,font=("Segoe UI",9),anchor="e").pack(side="right",fill="x",expand=True)

        panes=tk.PanedWindow(self.root,orient="horizontal",bg=self.BG,bd=0,sashwidth=10,height=300); panes.pack(side="top",fill="both",expand=True,padx=20)
        self.input,ic=self.card(panes,"原文",False); self.output,oc=self.card(panes,"译文",True)
        panes.add(ic,minsize=250); panes.add(oc,minsize=250)
    def card(self,parent,title,readonly):
        card=tk.Frame(parent,bg=self.CARD,highlightbackground=self.BORDER,highlightthickness=1)
        tk.Label(card,text=title,bg=self.CARD,fg=self.TEXT,font=("Segoe UI Semibold",10)).pack(anchor="w",padx=12,pady=(10,5))
        box=tk.Text(card,wrap="word",bg=self.CARD,fg=self.TEXT,relief="flat",bd=0,padx=12,pady=8,font=("Segoe UI",10),insertbackground=self.BLUE,selectbackground=self.BLUE,selectforeground="white")
        sb=ModernScrollbar(card,command=box.yview,width=10)
        box.configure(yscrollcommand=sb.set)
        sb.pack(side="right",fill="y",pady=5,padx=(0,3))
        box.pack(side="left",fill="both",expand=True)
        if readonly:box.configure(state="disabled")
        return box,card
    def set_output(self,value):
        self.output.configure(state="normal"); self.output.delete("1.0","end"); self.output.insert("1.0",value); self.output.configure(state="disabled")
    def clear_content(self):
        if self.busy:self.status.set("翻译进行中，暂不能清空");return
        self.input.delete("1.0","end");self.set_output("");self.input.focus_set();self.status.set("内容已清空")
    def capture(self,n=0):
        try:
            value=self.root.clipboard_get()
            if not isinstance(value,str) or not value.strip():raise tk.TclError()
            self.input.delete("1.0","end");self.input.insert("1.0",value);self.root.deiconify();self.root.lift();self.start()
        except tk.TclError:
            if n<5:self.root.after(160,lambda:self.capture(n+1))
            else:self.status.set("未读取到剪贴板文本")
    def start(self):
        if self.busy:return
        text=self.input.get("1.0","end-1c")
        if not text.strip():self.status.set("请输入需要翻译的文本");return
        src,dst=LANGUAGES[self.src.get()],LANGUAGES[self.dst.get()]
        if src=="auto":
            src,auto_dst=pair(text)
            if self.dst.get() in ("简体中文","英语"):dst=auto_dst;self.dst.set("英语" if dst=="en" else "简体中文")
        if src==dst:self.status.set("源语言和目标语言不能相同");return
        self.busy=True;self.go.configure(state="disabled");self.clear.configure(state="disabled");self.set_output("")
        threading.Thread(target=self.worker,args=(text,src,dst,self.provider.get(),self.keep_layout.get()),daemon=True).start()
    def worker(self,text,src,dst,provider,preserve_layout):
        try:
            actual=provider
            if preserve_layout:
                units=layout_units(text)
                total=sum(len(chunks(core)) for _,core,_,_,translate in units if translate and core)
                done=0; rendered=[]
                for prefix,core,suffix,ending,translate in units:
                    if not translate or not core:
                        rendered.append(prefix+core+suffix+ending); continue
                    translated=[]
                    for part in chunks(core):
                        done+=1
                        self.events.put(("status",f"正在翻译 {done}/{max(1,total)} · {actual}"))
                        value,actual=translate_piece(part,src,dst,provider); translated.append(value)
                    rendered.append(prefix+"".join(translated)+suffix+ending)
                result="".join(rendered)
            else:
                out=[]; parts=chunks(text)
                for i,part in enumerate(parts,1):
                    self.events.put(("status",f"正在翻译 {i}/{len(parts)} · {actual}"))
                    value,actual=translate_piece(part,src,dst,provider); out.append(value)
                result="".join(out)
            self.events.put(("done",(result,actual)))
        except Exception as e:
            log_error(repr(e));self.events.put(("error",str(e)))
    def poll(self):
        try:
            while True:
                kind,value=self.events.get_nowait()
                if kind=="clip":self.root.after(180,lambda:self.capture(0))
                elif kind=="status":self.status.set(value)
                elif kind=="done":self.busy=False;self.go.configure(state="normal");self.clear.configure(state="normal");self.set_output(value[0]);self.status.set("翻译完成 · "+value[1])
                elif kind=="error":self.busy=False;self.go.configure(state="normal");self.clear.configure(state="normal");self.set_output("翻译失败：\n"+value);self.status.set("翻译失败")
        except queue.Empty:pass
        self.root.after(80,self.poll)
    def copy_result(self):
        value=self.output.get("1.0","end-1c")
        if value:self.root.clipboard_clear();self.root.clipboard_append(value);self.root.update();self.status.set("译文已复制")
    def quit(self):
        try:self.hook.stop()
        finally:self.root.destroy()


CHILD_ARG = "--wgime-translate-window"


def _window_main():
    if sys.platform != "win32":
        raise SystemExit("Windows only")
    root = tk.Tk()
    App(root)
    root.mainloop()


def _start_detached_window():
    # WGIME 的纯 Python 插件入口必须尽快返回。翻译窗口在独立进程中运行，
    # 不受 txt [python] 块的 60 秒超时限制，也不会阻塞候选框收尾。
    import subprocess
    script = str(Path(__file__).resolve())
    creationflags = (getattr(subprocess, "DETACHED_PROCESS", 0x00000008) |
                     getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200) |
                     getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000))
    subprocess.Popen(
        [sys.executable, script, CHILD_ARG],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        creationflags=creationflags,
    )


def run():
    if sys.platform != "win32":
        return
    _start_detached_window()
    return


if __name__ == "__main__" and CHILD_ARG in sys.argv:
    _window_main()
