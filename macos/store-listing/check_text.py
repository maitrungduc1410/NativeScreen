# Checks every listing in text/ against App Store Connect's limits before you paste it in:
#   python3 macos/store-listing/check_text.py
import glob, os, re, sys

LIMITS = {"Subtitle": 30, "Promotional Text": 170, "Description": 4000}
KEYWORD_BYTES = 100

def sections(text):
    parts = re.split(r"^## (.+)$", text, flags=re.M)
    return {parts[i].strip(): parts[i + 1].strip() for i in range(1, len(parts), 2)}

ok = True
here = os.path.dirname(os.path.abspath(__file__))
for path in sorted(glob.glob(os.path.join(here, "text", "*.md"))):
    name = os.path.basename(path)
    s = sections(open(path, encoding="utf-8").read())
    report = []
    for key, limit in LIMITS.items():
        n = len(s.get(key, ""))
        if not n or n > limit:
            ok = False
            report.append(f"{key} {n}/{limit} !!")
        else:
            report.append(f"{key} {n}/{limit}")
    kw = s.get("Keywords", "")
    b = len(kw.encode("utf-8"))
    bad = not kw or b > KEYWORD_BYTES or ", " in kw
    ok &= not bad
    report.append(f"Keywords {b}/{KEYWORD_BYTES} bytes" + (" !!" if bad else ""))
    if re.search("[—–…]", "".join(s.values())):
        ok = False
        report.append("em dash, en dash or ellipsis !!")
    print(f"{name:14} " + " · ".join(report))
sys.exit(0 if ok else 1)
