"""
note.com の非公式・公開JSON APIから、カテゴリ別の人気記事を取得し、
最も勢いのあるジャンル（カテゴリ）を判定して JSON で出力する。

ログイン不要で読める公開エンドポイントのみを使用する:
  - GET https://note.com/api/v2/categories
  - GET https://note.com/api/v1/categories/{engName}?note_intro_only=true

使い方:
  python fetch_trends.py            # 上位5ジャンルを表示
  python fetch_trends.py --top 8    # 上位8ジャンルを表示
"""

import argparse
import json
import sys
import urllib.request
from urllib.error import URLError, HTTPError

BASE = "https://note.com"
HEADERS = {
    "Accept": "application/json",
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
}


def fetch_json(url: str):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.load(resp)


def get_categories():
    data = fetch_json(f"{BASE}/api/v2/categories")
    cats = data["data"]["categories"]
    # "注目"（category id/engName なし）は集計対象から除外
    return [c for c in cats if c.get("engName")]


def get_category_notes(eng_name: str):
    url = f"{BASE}/api/v1/categories/{eng_name}?note_intro_only=true"
    data = fetch_json(url)
    return data["data"].get("notes", [])


def score_category(notes):
    if not notes:
        return 0
    likes = [n.get("like_count", 0) or 0 for n in notes]
    return sum(likes) / len(likes)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--top", type=int, default=5, help="上位いくつのジャンルを出すか")
    parser.add_argument("--sample-size", type=int, default=5, help="各ジャンルの参考記事数")
    args = parser.parse_args()

    try:
        categories = get_categories()
    except (URLError, HTTPError) as e:
        print(json.dumps({"error": f"カテゴリ一覧の取得に失敗しました: {e}"}, ensure_ascii=False))
        sys.exit(1)

    results = []
    for cat in categories:
        eng = cat["engName"]
        try:
            notes = get_category_notes(eng)
        except (URLError, HTTPError) as e:
            print(f"warning: {cat['name']} の取得に失敗: {e}", file=sys.stderr)
            continue

        avg_likes = score_category(notes)
        top_notes = sorted(notes, key=lambda n: n.get("like_count", 0) or 0, reverse=True)
        samples = [
            {
                "title": n.get("name"),
                "like_count": n.get("like_count", 0),
                "url": n.get("note_url"),
                "excerpt": (n.get("body") or "")[:200],
            }
            for n in top_notes[: args.sample_size]
        ]

        results.append(
            {
                "category_id": cat.get("id"),
                "category_name": cat["name"],
                "eng_name": eng,
                "note_count_sampled": len(notes),
                "avg_like_count": round(avg_likes, 1),
                "top_articles": samples,
            }
        )

    results.sort(key=lambda r: r["avg_like_count"], reverse=True)

    output = {
        "generated_from": "note.com public category API",
        "ranked_genres": results[: args.top],
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
