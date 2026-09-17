语音包 wrapper (参考副本)
==========================

`wgime-stt.py` —— wgime 纯 Python 版的本地离线识别 wrapper (sherpa-onnx + SenseVoice-Small)。

为什么这里有一份、机器上还有一份
--------------------------------
真正在用的那份在**仓库外**: `C:\Tools\wgime-local-asr\wgime-stt.py`, 因为它是"语音包"的一部分 ——
和 228 MB 的模型 (`models\sense-voice\model.int8.onnx`) 一起按机器各装一份、可以整个目录搬到别的机器。
这一份是**参考副本**, 只为两件事:

1. **可读/可追溯**: 常驻 sherpa 的**客户端**在仓库里 (`wgime-py-pure\voice.py` 的 `_SherpaSrv` +
   `_WarmSrv`), 服务端的协议实现在这里 —— 改任何一侧都要同时看另一侧;
2. **防漂移**: `wgime-py-pure\tests\voicepack-sync-test.py` 会拿这份和 `config.txt` 里
   `stt_script` 指向的那份对比协议要点 (字节不同没关系, **协议 token 不同就 FAIL**)。

> 2026-09-16 就因为这个"一半在里、一半在外"出过一次缺口: 客户端已经改成"起 `stt_script --serve`",
> 而本机 wrapper 还是一次性版本 → `voice_engine = sherpa` 的助手根本起不来。

两种模式 (一份实现两处用)
-------------------------
```
# 一次性 (voice_engine = cmd): 每句重付一次载模型 ~1.3s; stdout **只打识别文本**
python wgime-stt.py <录音.wav> [--itn=0|1] [--lang=zh|auto] [--threads=N]

# 常驻 (voice_engine = sherpa): 启动载一次模型, 之后每句只解码
python -u wgime-stt.py --serve --itn=1 --threads=4 [--lang=zh]
  -> {"ready":true,"boot_ms":1312,"model":"sense-voice","itn":true,"lang":"zh"}
  <- {"id":1,"wav":"C:\\...\\a.wav"}
  -> {"id":1,"ok":true,"text":"今天天气不错，我们下午3点开会。","ms":1171,"segs":1,"audio_ms":4685}
  -> {"id":1,"ok":false,"error":"..."}        # 单句失败**不退出**
  <- {"cmd":"ping"}   -> {"id":1,"ok":true,"text":"","ms":0}
  <- {"cmd":"exit"} 或 stdin 关闭 = wgime 退出 -> 自己退
```
* 服务模式 stdout **只有 JSON 行**(日志一律 stderr)、回包 `ensure_ascii=True`;
* `--itn/--lang/--threads` 是**建识别器**的参数(改了要重启助手), 客户端按 `key` 自动重启。

装机 (每台机器各来一遍)
-----------------------
```powershell
python -m pip install sherpa-onnx                     # 会带上 sherpa-onnx-core
New-Item -ItemType Directory -Force C:\Tools\wgime-local-asr\models\sense-voice
$base = 'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main'
curl.exe -L --retry 5 -C - -o C:\Tools\wgime-local-asr\models\sense-voice\tokens.txt     "$base/tokens.txt"
curl.exe -L --retry 5 -C - -o C:\Tools\wgime-local-asr\models\sense-voice\model.int8.onnx "$base/model.int8.onnx"
# 校验: tokens.txt 315894 B、model.int8.onnx 239233841 B
```
config.txt:
```
voice = 1
voice_engine   = sherpa
stt_script     = C:\Tools\wgime-local-asr\wgime-stt.py
stt_itn        = 1
stt_threads    = 8        ; 实测本机 8 逻辑核时 8 最好 (2/4/8/16 -> 1532/1265/1171/1640 ms)
```
实测 (本机 Intel Core Ultra 7 155H, 音频 4.7s): 载模型 1312~2375 ms(只在启动付一次);
解码 ≈ 0.25~0.27 × 音频时长; 走 `voice.recognize()` 第一句 2.7~3.3s、第二句 1.1~1.4s。
**常驻省掉的是每句固定 ~1.3s 载模型**, 解码跟音频长度成正比 —— 短口令 0.1~0.2s,
按住说一句 2~3s 的话约 0.6~0.9s。

便携包
------
`C:\Tools\wgime-local-asr\portable\` 是"拿去其它设备"的整包 (wrapper + 模型 + wheels + 安装脚本),
里面的 wrapper 与这份**应当一致** (同步方式: 复制本文件过去)。
