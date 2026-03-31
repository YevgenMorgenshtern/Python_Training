#!/usr/bin/env bash
# ============================================================
# karaoke.sh — создаёт караоке-видео из YouTube ссылки
# macOS, без llvmlite/numba/demucs
#
# Зависимости: ffmpeg, yt-dlp, python3.12 (все через brew)
# Python: только faster-whisper (CTranslate2, без llvmlite)
#
# Использование:
#   ./karaoke.sh <youtube_url> <language> <outfile>
# Пример:
#   ./karaoke.sh "https://youtu.be/xxx" de karaoke_final.mp4
#   ./karaoke.sh "https://youtu.be/xxx" auto karaoke_final.mp4
# ============================================================
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Использование: $0 <youtube_url> <language> <outfile>"
  exit 1
fi

URL="$1"
LANG="$2"
OUTFILE="$3"
WORKDIR="karaoke_tmp"
mkdir -p "$WORKDIR"

# ---------- Homebrew-зависимости ----------
echo "🔍 Проверка зависимостей..."
if ! command -v brew &>/dev/null; then
  echo "❌ Homebrew не установлен: https://brew.sh"; exit 1
fi
for tool in ffmpeg yt-dlp; do
  command -v "$tool" &>/dev/null || brew install "$tool"
done
command -v python3.12 &>/dev/null || brew install python@3.12

# ---------- venv с faster-whisper ----------
VENV_DIR="$WORKDIR/venv"
if [ ! -d "$VENV_DIR" ]; then
  echo "🐍 Создаём venv..."
  python3.12 -m venv "$VENV_DIR"
fi
PY="$VENV_DIR/bin/python3"

"$PY" -m pip install -q --upgrade pip
"$PY" -m pip install -q faster-whisper

# ---------- шаг 1: скачать аудио ----------
echo "⬇️  Скачиваем аудио..."
yt-dlp -x --audio-format wav --no-playlist "$URL" -o "$WORKDIR/song.%(ext)s"
SONG_FILE=$(find "$WORKDIR" -maxdepth 1 -name "*.wav" | head -1)
[ -z "$SONG_FILE" ] && { echo "❌ Не удалось скачать аудио."; exit 1; }
if [ "$SONG_FILE" != "$WORKDIR/song.wav" ]; then
  cp "$SONG_FILE" "$WORKDIR/song.wav"
fi

# ---------- шаг 2: подавление вокала через ffmpeg ----------
# Используем фазовую инверсию (каналы L-R): убирает центральный вокал
echo "🎛️  Подавляем вокал (ffmpeg)..."
ffmpeg -y -i "$WORKDIR/song.wav" \
  -af "pan=stereo|c0=c0-c1|c1=c1-c0" \
  "$WORKDIR/accompaniment.wav" -loglevel error
echo "   → accompaniment.wav готов"

# ---------- шаг 3: транскрипция с таймингами по словам ----------
echo "🎙️  Транскрибируем (faster-whisper, язык: $LANG)..."
"$PY" - <<PYEOF
from faster_whisper import WhisperModel
import json

lang = None if "$LANG" == "auto" else "$LANG"
model = WhisperModel("large-v3", device="auto", compute_type="auto")
segments, info = model.transcribe(
    "$WORKDIR/song.wav",
    language=lang,
    word_timestamps=True,
    beam_size=5,
)

out = {"segments": []}
for seg in segments:
    words = [{"start": w.start, "end": w.end, "text": w.word} for w in (seg.words or [])]
    out["segments"].append({"start": seg.start, "end": seg.end, "text": seg.text, "words": words})

with open("$WORKDIR/vocals.json", "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print(f"Готово, сегментов: {len(out['segments'])}")
PYEOF

# ---------- шаг 4: генерация .ass субтитров ----------
echo "📝 Генерируем субтитры..."
export WORKDIR
"$PY" - <<'PYEOF'
import json, os
workdir = os.environ["WORKDIR"]
with open(f"{workdir}/vocals.json", encoding="utf-8") as f:
    data = json.load(f)

ass_header = """\
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Karaoke,Arial,52,&H00FFFFFF,&H0000FFFF,&H00000000,&H90000000,1,0,0,0,100,100,2,0,1,3,1,2,10,10,60,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

def fmt(s):
    h, m = int(s // 3600), int((s % 3600) // 60)
    return f"{h}:{m:02d}:{s % 60:05.2f}"

lines = []
for seg in data["segments"]:
    kt = ""
    for w in seg.get("words", []):
        cs = max(1, int((w["end"] - w["start"]) * 100))
        kt += "{\\k" + str(cs) + "}" + w["text"].strip() + " "
    if kt.strip():
        lines.append(f"Dialogue: 0,{fmt(seg['start'])},{fmt(seg['end'])},Karaoke,,0,0,0,,{kt.strip()}")

with open(f"{workdir}/karaoke.ass", "w", encoding="utf-8") as f:
    f.write(ass_header + "\n".join(lines))
print(f"karaoke.ass готов, строк: {len(lines)}")
PYEOF

# ---------- шаг 5: скачать видео ----------
echo "⬇️  Скачиваем видео..."
yt-dlp -f "bestvideo[ext=mp4][height<=1080]" --no-playlist "$URL" -o "$WORKDIR/video.mp4"

# ---------- шаг 6: финальная сборка ----------
echo "🎬 Собираем финальное видео..."

# Используем libx264 — VideoToolbox не поддерживает AV1 входной поток
echo "   → libx264"

# subtitles фильтр ищет файл относительно cwd — копируем туда
cp "$WORKDIR/karaoke.ass" "./karaoke_render.ass"

ffmpeg -y \
  -i "$WORKDIR/video.mp4" \
  -i "$WORKDIR/accompaniment.wav" \
  -vf "subtitles=karaoke_render.ass" \
  -map 0:v -map 1:a \
  -c:v libx264 -preset fast -crf 20 \
  -c:a aac -b:a 192k \
  "$OUTFILE"

rm -f "./karaoke_render.ass"

echo ""
echo "✅ Готово! Файл: $OUTFILE"
echo "🗑️  Временные файлы: $WORKDIR (можно удалить)"
