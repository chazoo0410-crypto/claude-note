/* muziy — カタログ描画・カート・ご注文内容の作成 */
(() => {
  "use strict";

  const PRODUCTS = window.MUZIY_PRODUCTS || [];
  const INSTAGRAM = "https://www.instagram.com/muziy.696";
  const SHIPPING = 370;
  const FREE_OVER = 5000;
  const STORE_KEY = "muziy.cart.v1";

  const $  = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const yen = n => "¥" + n.toLocaleString("ja-JP");
  const byNo = no => PRODUCTS.find(p => p.no === no);

  /* ============================================================
     仮のイラスト（写真が入るまでのプレースホルダー）
     ============================================================ */
  const TONE = {
    pearl: "#E9E3D7",
    gold:  "#C9A45C",
    brass: "#A9803F",
    shell: "#DCE2E0",
    stone: "#7E8FA0",
    resin: "#D8CFC2"
  };
  const LIGHT = "#F2F1EB";
  const W = 440, H = 550, DPR = 2;

  const cssVar = name =>
    getComputedStyle(document.documentElement).getPropertyValue(name).trim() || "#1E211D";

  function rng(seed) {
    let s = (seed * 9301 + 49297) % 233280;
    return () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
  }

  function earwire(ctx, x, y) {           // 返り値 = 作品がぶら下がる位置
    ctx.beginPath();
    ctx.moveTo(x, y + 22);
    ctx.lineTo(x, y + 8);
    ctx.arc(x - 9, y + 8, 9, 0, Math.PI, true);
    ctx.lineTo(x - 18, y + 17);
    ctx.stroke();
    return y + 22;
  }

  function bead(ctx, x, y, r, fill, ink) {
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fillStyle = fill; ctx.fill();
    ctx.strokeStyle = ink; ctx.lineWidth = 1.1; ctx.stroke();
  }

  function drawPiece(canvas, p) {
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    canvas.width = W * DPR; canvas.height = H * DPR;
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.clearRect(0, 0, W, H);

    const ink  = cssVar("--ink");
    const soft = cssVar("--ink-2");
    const fill = TONE[p.tone] || TONE.pearl;
    const rand = rng(parseInt(p.no, 10) * 37 + 11);

    // 紙のざらつき
    ctx.fillStyle = soft; ctx.globalAlpha = .07;
    for (let i = 0; i < 150; i++) {
      ctx.beginPath();
      ctx.arc(rand() * W, rand() * H, rand() * 1.1 + .3, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;

    ctx.save();
    ctx.translate(W / 2, H / 2);
    ctx.scale(1.15, 1.15);
    ctx.translate(-W / 2, -H / 2 + 14);
    ctx.strokeStyle = ink;
    ctx.lineWidth = 1.6;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";

    const pair = fn => { fn(150); fn(290); };

    switch (p.kind) {
      case "drop":
        pair(x => {
          const hang = earwire(ctx, x, 150);
          ctx.beginPath(); ctx.moveTo(x, hang); ctx.lineTo(x, hang + 58); ctx.stroke();
          ctx.beginPath();
          ctx.ellipse(x, hang + 80, 15, 21, 0, 0, Math.PI * 2);
          ctx.fillStyle = fill; ctx.fill();
          ctx.strokeStyle = ink; ctx.lineWidth = 1.3; ctx.stroke();
          ctx.beginPath();
          ctx.ellipse(x - 5, hang + 73, 4, 7, -.4, 0, Math.PI * 2);
          ctx.fillStyle = LIGHT; ctx.globalAlpha = .8; ctx.fill(); ctx.globalAlpha = 1;
          ctx.lineWidth = 1.6;
        });
        break;

      case "hoop":
        pair(x => {
          const hang = earwire(ctx, x, 146);
          ctx.beginPath(); ctx.arc(x, hang + 46, 44, 0, Math.PI * 2);
          ctx.strokeStyle = fill; ctx.lineWidth = 6; ctx.stroke();
          ctx.strokeStyle = ink; ctx.lineWidth = 1; ctx.globalAlpha = .5; ctx.stroke();
          ctx.globalAlpha = 1; ctx.lineWidth = 1.6; ctx.strokeStyle = ink;
        });
        break;

      case "cluster":
        pair(x => {
          const hang = earwire(ctx, x, 150);
          ctx.beginPath(); ctx.moveTo(x, hang); ctx.lineTo(x, hang + 14); ctx.stroke();
          for (let i = 0; i < 7; i++) {
            const a = rand() * Math.PI * 2, d = rand() * 20;
            bead(ctx, x + Math.cos(a) * d, hang + 34 + Math.sin(a) * d * .9,
                 6 + rand() * 4, i % 3 === 0 ? TONE.gold : fill, ink);
          }
          ctx.lineWidth = 1.6;
        });
        break;

      case "stud":
        pair(x => {
          bead(ctx, x, 236, 18, fill, ink);
          ctx.beginPath(); ctx.arc(x, 236, 11, Math.PI * 1.05, Math.PI * 1.55);
          ctx.strokeStyle = LIGHT; ctx.lineWidth = 3; ctx.stroke();
          ctx.strokeStyle = ink; ctx.lineWidth = 1.6;
          ctx.globalAlpha = .45;
          ctx.beginPath(); ctx.moveTo(x, 254); ctx.lineTo(x, 272); ctx.stroke();
          ctx.globalAlpha = 1;
        });
        break;

      case "bar":
        pair(x => {
          const hang = earwire(ctx, x, 146);
          ctx.beginPath();
          if (ctx.roundRect) ctx.roundRect(x - 5.5, hang + 8, 11, 76, 5.5);
          else ctx.rect(x - 5.5, hang + 8, 11, 76);
          ctx.fillStyle = fill; ctx.fill();
          ctx.strokeStyle = ink; ctx.lineWidth = 1.3; ctx.stroke();
          ctx.lineWidth = 1.6;
        });
        break;

      case "pendant": {
        ctx.beginPath();
        ctx.moveTo(58, 140);
        ctx.bezierCurveTo(118, 292, 322, 292, 382, 140);
        ctx.stroke();
        bead(ctx, 220, 258, 7, "transparent", ink);
        ctx.beginPath();
        ctx.ellipse(220, 300, 21, 28, 0, 0, Math.PI * 2);
        ctx.fillStyle = fill; ctx.fill();
        ctx.strokeStyle = ink; ctx.lineWidth = 1.4; ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(210, 286); ctx.lineTo(230, 312);
        ctx.strokeStyle = "#C9DAE6"; ctx.lineWidth = 4; ctx.globalAlpha = .85; ctx.stroke();
        ctx.globalAlpha = 1; ctx.strokeStyle = ink; ctx.lineWidth = 1.6;
        break;
      }

      case "clip": {
        ctx.beginPath();
        if (ctx.roundRect) ctx.roundRect(92, 286, 256, 20, 10);
        else ctx.rect(92, 286, 256, 20);
        ctx.fillStyle = fill; ctx.fill(); ctx.stroke();
        [[142, 272], [220, 264], [298, 272]].forEach(([cx, cy]) => {
          for (let i = 0; i < 5; i++) {
            const a = (i / 5) * Math.PI * 2 + rand();
            bead(ctx, cx + Math.cos(a) * 11, cy + Math.sin(a) * 11, 4.6, LIGHT, ink);
          }
          bead(ctx, cx, cy, 3.4, TONE.gold, ink);
        });
        ctx.lineWidth = 1.6;
        break;
      }

      case "band": {
        const n = 18, R = 96;
        for (let i = 0; i < n; i++) {
          const a = (i / n) * Math.PI * 2 - Math.PI / 2;
          bead(ctx, 220 + Math.cos(a) * R, 272 + Math.sin(a) * R,
               i % 2 ? 9 : 10.5, i % 2 ? LIGHT : fill, ink);
        }
        break;
      }
    }
    ctx.restore();
  }

  function figure(p, cls = "fig-box") {
    const box = document.createElement("div");
    box.className = cls;
    if (p.image) {
      const img = document.createElement("img");
      img.src = p.image;
      img.alt = `${p.name} ${p.sub}`;
      img.loading = "lazy";
      box.append(img);
    } else {
      const cv = document.createElement("canvas");
      cv.dataset.no = p.no;
      cv.setAttribute("role", "img");
      cv.setAttribute("aria-label", `${p.name}（${p.sub}）のイメージ図。写真は準備中です`);
      box.append(cv);
      drawPiece(cv, p);
    }
    return box;
  }

  const redrawAll = () =>
    $$("canvas[data-no]").forEach(cv => { const p = byNo(cv.dataset.no); if (p) drawPiece(cv, p); });

  /* ============================================================
     カタログ
     ============================================================ */
  const grid = $("#grid");

  function stockTag(p) {
    if (p.stock === 0) return { text: "SOLD OUT", kind: "sold" };
    if (p.stock <= 2)  return { text: `残り${p.stock}点`, kind: "last" };
    return null;
  }

  function renderGrid(filter = "すべて") {
    grid.textContent = "";
    PRODUCTS
      .filter(p => filter === "すべて" || p.category === filter)
      .forEach(p => {
        const card = document.createElement("button");
        card.type = "button";
        card.className = "plate";
        card.dataset.no = p.no;

        const fig = figure(p);
        const tag = stockTag(p);
        if (tag) {
          const t = document.createElement("span");
          t.className = "tag"; t.dataset.kind = tag.kind; t.textContent = tag.text;
          fig.append(t);
        }

        const body = document.createElement("div");
        body.innerHTML =
          `<p class="plate-no">No. ${p.no}</p>` +
          `<h3>${p.name}<small>${p.reading}</small></h3>` +
          `<p class="plate-sub">${p.sub}</p>` +
          `<p class="plate-mat">${p.spec["素材"]}</p>`;

        const foot = document.createElement("div");
        foot.className = "plate-foot";
        foot.innerHTML =
          `<span class="price">${yen(p.price)}<small>税込</small></span>` +
          `<span class="more">詳しく →</span>`;

        card.append(fig, body, foot);
        card.addEventListener("click", () => openDetail(p.no));
        grid.append(card);
      });
  }

  $$(".chip").forEach(chip => {
    chip.addEventListener("click", () => {
      $$(".chip").forEach(c => c.setAttribute("aria-pressed", String(c === chip)));
      renderGrid(chip.dataset.cat);
    });
  });

  /* ============================================================
     作品ページ（スライドオーバー）
     ============================================================ */
  const detail = $("#detail");
  let detailQty = 1;

  function openDetail(no) {
    const p = byNo(no);
    if (!p) return;
    detailQty = 1;

    const body = $("#detail-body");
    body.textContent = "";

    const figWrap = document.createElement("div");
    figWrap.className = "detail-fig";
    figWrap.append(figure(p));
    body.append(figWrap);

    const head = document.createElement("div");
    head.innerHTML =
      `<p class="detail-no">No. ${p.no}</p>` +
      `<h3 class="detail-name">${p.name}<small>${p.reading}</small></h3>` +
      `<p class="detail-sub">${p.sub}</p>` +
      `<p class="detail-price">${yen(p.price)}<small>税込・送料別</small></p>` +
      `<p class="stockline"><span class="dot" data-kind="${p.stock === 0 ? "sold" : "ok"}"></span>` +
      `${p.stock === 0 ? "完売しました（再制作をご希望の方はDMでご相談ください）" : `在庫 ${p.stock}点`}</p>` +
      `<p class="detail-note">${p.note}</p>`;
    body.append(head);

    const spec = document.createElement("div");
    spec.className = "spec";
    const dl = document.createElement("dl");
    dl.className = "deflist";
    Object.entries(p.spec).forEach(([k, v]) => {
      const row = document.createElement("div");
      row.innerHTML = `<dt>${k}</dt><dd>${v}</dd>`;
      dl.append(row);
    });
    spec.innerHTML = "<h4>仕様</h4>";
    spec.append(dl);
    body.append(spec);

    const foot = $("#detail-foot");
    foot.textContent = "";
    if (p.stock === 0) {
      const a = document.createElement("a");
      a.className = "btn btn-line btn-block";
      a.href = INSTAGRAM; a.target = "_blank"; a.rel = "noopener";
      a.textContent = "Instagram で再制作を相談する";
      foot.append(a);
    } else {
      const row = document.createElement("div");
      row.className = "buyrow";
      row.innerHTML =
        `<div class="qty"><button type="button" data-step="-1" aria-label="数量を減らす">−</button>` +
        `<output id="detail-qty">1</output>` +
        `<button type="button" data-step="1" aria-label="数量を増やす">＋</button></div>` +
        `<button type="button" class="btn btn-fill" id="add">カートに入れる</button>`;
      foot.append(row);
      row.querySelectorAll("[data-step]").forEach(b => {
        b.addEventListener("click", () => {
          detailQty = Math.min(p.stock, Math.max(1, detailQty + Number(b.dataset.step)));
          $("#detail-qty").value = detailQty;
        });
      });
      $("#add").addEventListener("click", () => {
        addToCart(p.no, detailQty);
        detail.close();
        openCart();
      });
    }

    body.scrollTop = 0;
    detail.showModal();
  }

  /* ============================================================
     カート
     ============================================================ */
  let cart = [];
  try {
    cart = JSON.parse(localStorage.getItem(STORE_KEY) || "[]");
    if (!Array.isArray(cart)) cart = [];
  } catch (_) { cart = []; }
  cart = cart.filter(i => byNo(i.no));

  const save = () => { try { localStorage.setItem(STORE_KEY, JSON.stringify(cart)); } catch (_) {} };
  const count = () => cart.reduce((n, i) => n + i.qty, 0);
  const subtotal = () => cart.reduce((n, i) => n + byNo(i.no).price * i.qty, 0);
  const shipping = () => (cart.length === 0 || subtotal() >= FREE_OVER ? 0 : SHIPPING);

  function addToCart(no, qty) {
    const p = byNo(no);
    const line = cart.find(i => i.no === no);
    if (line) line.qty = Math.min(p.stock, line.qty + qty);
    else cart.push({ no, qty: Math.min(p.stock, qty) });
    save(); syncBadge();
  }
  function setQty(no, qty) {
    const p = byNo(no);
    const line = cart.find(i => i.no === no);
    if (!line) return;
    line.qty = Math.min(p.stock, Math.max(1, qty));
    save(); syncBadge(); renderCart();
  }
  function removeLine(no) {
    cart = cart.filter(i => i.no !== no);
    save(); syncBadge(); renderCart();
  }

  const cartBtn = $("#cart-open");
  function syncBadge() {
    const n = count();
    $("#cart-count").textContent = n;
    cartBtn.dataset.empty = n === 0 ? "1" : "0";
  }

  const cartDlg = $("#cart");
  const openCart = () => { renderCart(); cartDlg.showModal(); };

  function renderCart() {
    const body = $("#cart-body");
    const foot = $("#cart-foot");
    body.textContent = ""; foot.textContent = "";

    if (cart.length === 0) {
      body.innerHTML = `<p class="empty">カートはまだ空です。<br>気になる作品を選んでみてください。</p>`;
      return;
    }

    const ul = document.createElement("ul");
    ul.className = "cart-list";
    cart.forEach(item => {
      const p = byNo(item.no);
      const li = document.createElement("li");
      li.append(figure(p, "cart-thumb"));

      const info = document.createElement("div");
      info.innerHTML =
        `<p class="cart-name">${p.name}</p>` +
        `<p class="cart-sub">No. ${p.no} ／ ${p.sub}</p>`;

      const row = document.createElement("div");
      row.className = "cart-row";
      row.innerHTML =
        `<div class="qty sm"><button type="button" data-step="-1" aria-label="数量を減らす">−</button>` +
        `<output>${item.qty}</output>` +
        `<button type="button" data-step="1" aria-label="数量を増やす">＋</button></div>` +
        `<button type="button" class="linkish">削除</button>` +
        `<span class="price">${yen(p.price * item.qty)}</span>`;
      row.querySelectorAll("[data-step]").forEach(b =>
        b.addEventListener("click", () => setQty(item.no, item.qty + Number(b.dataset.step))));
      row.querySelector(".linkish").addEventListener("click", () => removeLine(item.no));

      info.append(row);
      li.append(info);
      ul.append(li);
    });
    body.append(ul);

    const memo = document.createElement("div");
    memo.className = "field";
    memo.innerHTML =
      `<label for="memo">ご要望・ご質問（任意）</label>` +
      `<textarea id="memo" placeholder="例：イヤリング金具に変更希望、ブレスレットを内周15cmに"></textarea>`;
    body.append(memo);

    const sub = subtotal(), ship = shipping();
    const totals = document.createElement("div");
    totals.className = "totals";
    totals.innerHTML =
      `<div><span>小計</span><span>${yen(sub)}</span></div>` +
      `<div><span>送料（レターパックライト）</span><span>${ship === 0 ? "無料" : yen(ship)}</span></div>` +
      (ship === 0
        ? `<div class="freeship"><span>${FREE_OVER.toLocaleString("ja-JP")}円以上のご注文のため送料無料です</span></div>`
        : `<div class="freeship"><span>あと${yen(FREE_OVER - sub)}で送料無料になります</span></div>`) +
      `<div class="sum"><span>合計</span><span>${yen(sub + ship)}</span></div>`;
    foot.append(totals);

    const go = document.createElement("button");
    go.type = "button";
    go.className = "btn btn-fill btn-block";
    go.textContent = "ご注文内容をまとめる";
    go.addEventListener("click", showOrder);
    foot.append(go);

    const hint = document.createElement("p");
    hint.className = "cart-sub";
    hint.style.textAlign = "center";
    hint.textContent = "オンライン決済は準備中です。内容をコピーしてDMからお送りください。";
    foot.append(hint);
  }

  function orderText() {
    const lines = ["muziy ご注文内容", "──────────────"];
    cart.forEach(i => {
      const p = byNo(i.no);
      lines.push(`No.${p.no} ${p.name}（${p.sub}） ×${i.qty}　${yen(p.price * i.qty)}`);
    });
    const sub = subtotal(), ship = shipping();
    lines.push("──────────────");
    lines.push(`小計　${yen(sub)}`);
    lines.push(`送料　${ship === 0 ? "無料" : yen(ship)}`);
    lines.push(`合計　${yen(sub + ship)}`);
    const memo = $("#memo") && $("#memo").value.trim();
    if (memo) { lines.push("──────────────"); lines.push(`ご要望：${memo}`); }
    return lines.join("\n");
  }

  function showOrder() {
    const text = orderText();
    const body = $("#cart-body");
    const foot = $("#cart-foot");
    body.textContent = ""; foot.textContent = "";

    const intro = document.createElement("p");
    intro.className = "detail-note";
    intro.style.marginTop = "0";
    intro.textContent =
      "下の内容をコピーして、Instagram のDMからお送りください。お支払い方法とお届け先の確認を折り返しご案内します。";
    body.append(intro);

    const ta = document.createElement("textarea");
    ta.className = "orderbox";
    ta.readOnly = true;
    ta.value = text;
    ta.id = "orderbox";
    body.append(ta);

    const msg = document.createElement("p");
    msg.className = "copied";
    body.append(msg);

    const copy = document.createElement("button");
    copy.type = "button";
    copy.className = "btn btn-line btn-block";
    copy.textContent = "注文内容をコピー";
    copy.addEventListener("click", async () => {
      ta.select();
      let ok = false;
      try { await navigator.clipboard.writeText(text); ok = true; } catch (_) {
        try { ok = document.execCommand("copy"); } catch (_) { ok = false; }
      }
      msg.textContent = ok ? "コピーしました。DMに貼り付けてください。"
                           : "コピーできませんでした。上の文章を選択してコピーしてください。";
    });
    foot.append(copy);

    const dm = document.createElement("a");
    dm.className = "btn btn-fill btn-block";
    dm.href = INSTAGRAM; dm.target = "_blank"; dm.rel = "noopener";
    dm.textContent = "Instagram を開く";
    foot.append(dm);

    const back = document.createElement("button");
    back.type = "button";
    back.className = "linkish";
    back.style.justifySelf = "center";
    back.textContent = "← カートに戻る";
    back.addEventListener("click", renderCart);
    foot.append(back);
  }

  /* ============================================================
     起動
     ============================================================ */
  cartBtn.addEventListener("click", openCart);
  $$("[data-close]").forEach(b => b.addEventListener("click", () => b.closest("dialog").close()));
  $$("dialog").forEach(d => d.addEventListener("click", e => { if (e.target === d) d.close(); }));

  renderGrid();
  syncBadge();

  // ヒーローの標本棚
  $$("#vitrine [data-no]").forEach(slot => {
    const p = byNo(slot.dataset.no);
    if (p) slot.prepend(figure(p));
  });

  // テーマ切り替えに追従して線の色を描き直す
  const mq = window.matchMedia("(prefers-color-scheme: dark)");
  (mq.addEventListener ? mq.addEventListener.bind(mq, "change") : mq.addListener.bind(mq))(redrawAll);
  new MutationObserver(redrawAll).observe(document.documentElement, { attributeFilter: ["data-theme"] });
})();
