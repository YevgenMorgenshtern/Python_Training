#!/usr/bin/env bash
# ============================================================
# karaoke.sh — создаёт домашнее караоке-видео
#
# Использование:
#   ./karaoke.sh <youtube_url_песни> <youtube_url_видео> <язык> <outfile>
#
# Пример:
#   ./karaoke.sh "https://youtu.be/AAA" "https://youtu.be/BBB" ru karaoke.mp4
#
# Если видеоряд и песня — одно видео:
#   ./karaoke.sh "https://youtu.be/AAA" "https://youtu.be/AAA" ru karaoke.mp4
# ============================================================
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Использование: $0 <url_песни> <url_видео> <язык> <outfile>"
  exit 1
fi

URL_SONG="$1"
URL_VIDEO="$2"
LANG="$3"
OUTFILE="$4"
WORKDIR="karaoke_tmp"
mkdir -p "$WORKDIR"

# ---------- Homebrew-зависимости ----------
echo "🔍 Проверка зависимостей..."
if ! command -v brew &>/dev/null; then
  echo "❌ Homebrew не установлен: https://brew.sh"; exit 1
fi
for tool in ffmpeg-full yt-dlp; do
  command -v "${tool%%-*}" &>/dev/null || brew install "$tool"
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

# ============================================================
# ШАГ 1: Скачать аудио
# ============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ШАГ 1 из 5: Скачиваем аудио с YouTube"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ ! -f "$WORKDIR/song.mp3" ]; then
  yt-dlp -x --audio-format mp3 --audio-quality 0 \
    --no-playlist "$URL_SONG" -o "$WORKDIR/song.mp3"
  echo "✅ Аудио сохранено: $WORKDIR/song.mp3"
else
  echo "⏭️  Аудио уже есть, пропускаем."
fi

# ============================================================
# ШАГ 2: Удаление вокала (вручную через онлайн-сервис)
# ============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ШАГ 2 из 5: Удаление вокала"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$WORKDIR/instrumental.mp3" ] && [ ! -f "$WORKDIR/instrumental.wav" ]; then
  echo ""
  echo "  Загрузи файл  👉  $(pwd)/$WORKDIR/song.mp3"
  echo "  на один из сервисов:"
  echo ""
  echo "    • https://vocalremover.org  (бесплатно, без регистрации)"
  echo "    • https://lalal.ai          (10 мин бесплатно, лучше качество)"
  echo "    • https://music.ai          (есть бесплатный tier)"
  echo ""
  echo "  Скачай результат (instrumental / music / accompaniment)"
  echo "  и сохрани его как:"
  echo ""
  echo "    👉  $(pwd)/$WORKDIR/instrumental.mp3"
  echo ""
  read -r -p "  Готово? Нажми Enter чтобы продолжить... "

  # Проверяем что файл появился
  if [ ! -f "$WORKDIR/instrumental.mp3" ] && [ ! -f "$WORKDIR/instrumental.wav" ]; then
    echo "❌ Файл $WORKDIR/instrumental.mp3 не найден. Положи его туда и запусти скрипт снова."
    exit 1
  fi
fi

INSTRUMENTAL=$([ -f "$WORKDIR/instrumental.wav" ] && echo "$WORKDIR/instrumental.wav" || echo "$WORKDIR/instrumental.mp3")
echo "✅ Instrumental: $INSTRUMENTAL"

# ============================================================
# ШАГ 3: Транскрипция
# ============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ШАГ 3 из 5: Транскрипция (Whisper)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$WORKDIR/vocals.json" ]; then
  "$PY" - <<PYEOF
from faster_whisper import WhisperModel
import json

lang = None if "$LANG" == "auto" else "$LANG"
print(f"   → Модель: large-v3, язык: {lang or 'авто'}")
model = WhisperModel("large-v3", device="auto", compute_type="auto")
segments, info = model.transcribe(
    "$WORKDIR/song.mp3",
    language=lang,
    word_timestamps=True,
    beam_size=5,
    vad_filter=False,
    condition_on_previous_text=True,
    no_speech_threshold=0.6,
    log_prob_threshold=-1.0,
    compression_ratio_threshold=2.4,
    temperature=0.0,
)

out = {"segments": []}
for seg in segments:
    words = [{"start": w.start, "end": w.end, "text": w.word} for w in (seg.words or [])]
    out["segments"].append({"start": seg.start, "end": seg.end, "text": seg.text, "words": words})

with open("$WORKDIR/vocals.json", "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print(f"✅ Транскрипция готова, сегментов: {len(out['segments'])}")
PYEOF
else
  echo "⏭️  Транскрипция уже есть, пропускаем."
fi

# ============================================================
# ШАГ 4: Генерация субтитров
# ============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ШАГ 4 из 5: Генерация субтитров (.ass)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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
print(f"✅ Субтитры готовы, строк: {len(lines)}")
PYEOF

# ============================================================
# ШАГ 5: Скачать видеоряд и собрать финальное видео
# ============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ШАГ 5 из 5: Сборка финального видео"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$WORKDIR/video.mp4" ]; then
  echo "⬇️  Скачиваем видеоряд..."
  yt-dlp -f "bestvideo[ext=mp4][height<=1080]" \
    --no-playlist "$URL_VIDEO" -o "$WORKDIR/video.mp4"
  echo "✅ Видео сохранено."
else
  echo "⏭️  Видео уже есть, пропускаем."
fi

echo "🎬 Собираем финальное видео..."
cp "$WORKDIR/karaoke.ass" "./karaoke_render.ass"

ffmpeg -y \
  -i "$WORKDIR/video.mp4" \
  -i "$INSTRUMENTAL" \
  -vf "subtitles=karaoke_render.ass" \
  -map 0:v -map 1:a \
  -c:v libx264 -preset fast -crf 20 \
  -c:a aac -b:a 192k \
  "$OUTFILE"

rm -f "./karaoke_render.ass"

echo ""
echo "✅ Готово! Файл: $OUTFILE"
echo "🗑️  Временные файлы: $WORKDIR (можно удалить)"
