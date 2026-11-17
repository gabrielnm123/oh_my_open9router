#!/usr/bin/env python3
"""Sonda de QUALIDADE dos modelos (tools/quality_probe.py).

Ao contrario de `tools/probe-models.sh`, que mede apenas **alcance** (HTTP,
latencia e se o modelo devolve um tool call), este script executa tarefas
curtas e deterministicas com correcao automatica e produz uma nota de 0.0 a
1.0. E essa nota que o seletor usa para ordenar os candidatos por papel —
antes ela dependia apenas de pesquisa web, que nao mede o modelo de fato.

Tarefas (todas com resposta unica e verificavel, sem conhecimento externo):

  reasoning   contagem com criterio de divisibilidade (resposta: 95)
  json        saida estruturada com schema e valores exatos
  coding      fib(10) em Python (resposta: 55)
  instruction Vogais em ordem alfabetica, formato exato
  constraint  substituir numeros pares por uma letra, formato exato
  tool_call   tool call com o nome e os argumentos corretos

Uso:
  python3 tools/quality_probe.py \\
      --base-url "$NINEROUTER_BASE_URL" --api-key "$NINEROUTER_API_KEY" \\
      --model ag/claude-sonnet-4-6 [--timeout 60] [--out qualidade.jsonl]

  # varios modelos de uma vez (uma linha JSON por modelo)
  python3 tools/quality_probe.py --base-url ... --api-key ... \\
      --models ag/claude-sonnet-4-6,ag/gemini-3.8-flash

A saida e JSON Lines (uma linha por modelo) em `--out` ou no stdout. Este
script **nunca** quebra o chamador: erro de rede/modelo vira
`quality_score: 0.0` com `error` preenchido.
"""

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------- tarefas

TOOLS = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string", "description": "City name"}},
            "required": ["city"],
        },
    },
}]


def _numbers(text):
    return [int(x) for x in re.findall(r"-?\d+", text or "")]


def _extract_json(text):
    if not text:
        return None
    t = text.strip()
    t = re.sub(r"^```(?:json)?\s*", "", t, flags=re.I)
    t = re.sub(r"\s*```$", "", t).strip()
    try:
        json.loads(t)
        return t
    except Exception:
        pass
    i, j = t.find("{"), t.rfind("}")
    if i != -1 and j != -1 and j > i:
        return t[i:j + 1]
    return None


def _norm(value):
    s = (value or "").strip().lower()
    s = s.replace(" ", "")
    s = s.strip(".,;:")
    return s


def grade_reasoning(content, tool_calls):
    ok = 95 in _numbers(content)
    return ok, ("95 encontrado" if ok else "95 ausente")


def grade_json(content, tool_calls):
    raw = _extract_json(content)
    if raw is None:
        return False, "sem JSON"
    try:
        obj = json.loads(raw)
    except Exception as exc:
        return False, f"JSON invalido: {exc}"
    if not isinstance(obj, dict):
        return False, "nao e objeto"
    ok = (obj.get("soma") == 42 and obj.get("par") is True
          and obj.get("primos") == [2, 3, 5])
    return ok, json.dumps(obj, ensure_ascii=False)[:120]


def grade_coding(content, tool_calls):
    ok = 55 in _numbers(content)
    return ok, ("55 encontrado" if ok else "55 ausente")


def grade_instruction(content, tool_calls):
    got = _norm(content)
    ok = got == "a,e,i,o,u"
    return ok, got[:80]


def grade_constraint(content, tool_calls):
    got = _norm(content)
    ok = got == "1,p,3,p,5,p,7,p,9,p"
    return ok, got[:80]


def grade_tool_call(content, tool_calls):
    if not tool_calls:
        return False, "sem tool call"
    fn = (tool_calls[0] or {}).get("function") or {}
    if fn.get("name") != "get_weather":
        return False, f"tool errada: {fn.get('name')!r}"
    try:
        args = json.loads(fn.get("arguments") or "{}")
    except Exception:
        args = {}
    city = str(args.get("city") or "")
    if "paulo" not in _norm(city):
        return False, f"cidade errada: {city!r}"
    return True, city


TASKS = [
    {
        "id": "reasoning",
        "weight": 1.0,
        "max_tokens": 512,
        "messages": [{
            "role": "user",
            "content": (
                "Quantos numeros inteiros entre 1 e 1000, inclusive, sao "
                "divisiveis por 7 mas nao por 3? Pensa passo a passo e "
                "responde APENAS com o numero final."
            ),
        }],
        "grade": grade_reasoning,
    },
    {
        "id": "json",
        "weight": 1.0,
        "max_tokens": 256,
        "messages": [{
            "role": "user",
            "content": (
                'Gere um objeto JSON valido com exatamente estas chaves: '
                '"soma" (inteiro), "par" (booleano) e "primos" (array de 3 '
                "inteiros). soma = 17 + 25; par = se a soma e par; primos = "
                "os tres primeiros numeros primos. Responda APENAS com o JSON."
            ),
        }],
        "grade": grade_json,
    },
    {
        "id": "coding",
        "weight": 1.0,
        "max_tokens": 256,
        "messages": [{
            "role": "user",
            "content": (
                "Em Python, defina fib(n) com fib(0)=0 e fib(1)=1. Qual e o "
                "valor de fib(10)? Responda APENAS com o numero."
            ),
        }],
        "grade": grade_coding,
    },
    {
        "id": "instruction",
        "weight": 1.0,
        "max_tokens": 128,
        "messages": [{
            "role": "user",
            "content": (
                "Liste as cinco vogais do alfabeto portugues em ordem "
                "alfabetica, separadas por virgula e sem espacos. Responda "
                "apenas com a lista."
            ),
        }],
        "grade": grade_instruction,
    },
    {
        "id": "constraint",
        "weight": 1.0,
        "max_tokens": 128,
        "messages": [{
            "role": "user",
            "content": (
                "Conte de 1 a 10. Para cada numero par, escreva a letra P no "
                "lugar do numero. Separe os itens por virgula, sem espacos. "
                "Responda apenas com a lista."
            ),
        }],
        "grade": grade_constraint,
    },
    {
        "id": "tool_call",
        "weight": 1.0,
        "max_tokens": 256,
        "messages": [{
            "role": "user",
            "content": "Chame a ferramenta get_weather para a cidade Sao Paulo.",
        }],
        "tools": TOOLS,
        "grade": grade_tool_call,
    },
]

TOTAL_WEIGHT = sum(t["weight"] for t in TASKS)


# ------------------------------------------------------------------ requisicao

def _post(url, api_key, payload, timeout):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            # O relay fica atras de CDN/WAF: o User-Agent padrao do urllib e
            # bloqueado (HTTP 403, "error code: 1010"). Usamos o mesmo
            # identificador que o `curl` da sonda de alcance usa.
            "User-Agent": "curl/8.5.0",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")


def _parse(raw, http_status):
    """Devolve (content, tool_calls, erro)."""
    if http_status != 200:
        return "", [], f"HTTP {http_status}"
    try:
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        return "", [], (raw[:200] or "resposta nao-JSON")
    err = data.get("error")
    if isinstance(err, dict):
        return "", [], str(err.get("message") or err)[:200]
    if err:
        return "", [], str(err)[:200]
    choices = data.get("choices") or []
    msg = (choices[0] if choices else {}).get("message") or {}
    content = msg.get("content") or ""
    tool_calls = msg.get("tool_calls") or []
    return content, tool_calls, None


def run_task(task, base_url, api_key, model, timeout):
    payload = {
        "model": model,
        "stream": False,
        "max_tokens": task["max_tokens"],
        "messages": task["messages"],
    }
    if task.get("tools"):
        payload["tools"] = task["tools"]
        payload["tool_choice"] = "auto"

    started = time.time()
    error = None
    content, tool_calls = "", []
    try:
        status, raw = _post(f"{base_url}/chat/completions", api_key, payload, timeout)
        # Alguns gateways rejeitam `tool_choice` (HTTP 400). Sem ele o modelo
        # ainda pode suportar tools; o que importa e o tool call em si.
        if status == 400 and "tool_choice" in payload:
            payload.pop("tool_choice", None)
            status, raw = _post(f"{base_url}/chat/completions", api_key, payload, timeout)
        content, tool_calls, error = _parse(raw, status)
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", "replace")
        except Exception:
            pass
        content, tool_calls, error = _parse(body, exc.code)
    except Exception as exc:  # rede, timeout, DNS...
        error = f"{type(exc).__name__}: {exc}"[:200]

    try:
        ok, detail = task["grade"](content, tool_calls)
    except Exception as exc:
        ok, detail = False, f"correcao falhou: {exc}"

    return {
        "id": task["id"],
        "weight": task["weight"],
        "ok": bool(ok),
        "detail": (detail or "")[:160],
        "elapsed_ms": int((time.time() - started) * 1000),
        "error": error,
    }


def probe_model(model, base_url, api_key, timeout):
    started = time.time()
    tasks = [run_task(t, base_url, api_key, model, timeout) for t in TASKS]
    earned = sum(t["weight"] for t in tasks if t["ok"])
    score = round(earned / TOTAL_WEIGHT, 4) if TOTAL_WEIGHT else 0.0
    errors = [t["error"] for t in tasks if t.get("error")]
    return {
        "model": model,
        "quality_score": score,
        "tasks": tasks,
        "error": errors[0] if errors else None,
        "elapsed_ms": int((time.time() - started) * 1000),
    }


def main():
    ap = argparse.ArgumentParser(description="Sonda de qualidade dos modelos.")
    ap.add_argument("--base-url", required=True, help="URL base (ex.: https://.../v1)")
    ap.add_argument("--api-key", default="", help="Bearer token")
    ap.add_argument("--model", action="append", default=[], help="Modelo (repetivel)")
    ap.add_argument("--models", default="", help="Modelos separados por virgula")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--out", default="", help="Arquivo JSONL de saida (stdout se vazio)")
    args = ap.parse_args()

    models = list(args.model)
    if args.models:
        models += [m.strip() for m in args.models.split(",") if m.strip()]
    if not models:
        ap.error("informe --model ou --models")

    base_url = args.base_url.rstrip("/")
    records = [probe_model(m, base_url, args.api_key, args.timeout) for m in models]
    lines = [json.dumps(r, ensure_ascii=False) for r in records]
    blob = "\n".join(lines) + "\n"

    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(blob)
    else:
        sys.stdout.write(blob)
    return 0


if __name__ == "__main__":
    sys.exit(main())
