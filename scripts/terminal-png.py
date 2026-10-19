#!/usr/bin/env python3
"""Gera a imagem de uma "janela de terminal" a partir de um arquivo de texto.

    python3 scripts/terminal-png.py saida.txt img/saida.png [--titulo "lab@cp-1"] [--linhas 40]

Desenha um SVG (sem dependências) e converte para PNG com `rsvg-convert`.
Linhas que começam com "$ " são destacadas como comando. O texto de entrada já
deve estar higienizado (ver scripts/capturar-evidencias.sh).
"""

import argparse
import html
import subprocess
import sys
from pathlib import Path

FONTE = "DejaVu Sans Mono"
TAMANHO = 14
ALTURA_LINHA = 19
LARGURA_CARACTERE = 8.43  # largura média da DejaVu Sans Mono em 14 px
MARGEM = 18
BARRA = 34

CORES = {
    "fundo": "#1e1f29",
    "barra": "#2b2d3a",
    "texto": "#e6e6e6",
    "comando": "#7ee787",
    "prompt": "#79c0ff",
    "titulo": "#9aa0b4",
    "ok": "#7ee787",
    "alerta": "#f2cc60",
    "erro": "#ff7b72",
}


def cor_da_linha(linha: str) -> str:
    texto = linha.lower()
    if any(p in texto for p in ("failed=1", "fatal", "error", "notready", "crashloop")):
        return CORES["erro"]
    if any(p in texto for p in ("warning", "pending")):
        return CORES["alerta"]
    return CORES["texto"]


def gerar_svg(linhas: list[str], titulo: str) -> str:
    colunas = max((len(linha) for linha in linhas), default=40)
    largura = int(max(colunas, len(titulo) + 10) * LARGURA_CARACTERE + 2 * MARGEM)
    altura = BARRA + MARGEM + len(linhas) * ALTURA_LINHA + MARGEM

    partes = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{largura}" height="{altura}">',
        f'<rect width="{largura}" height="{altura}" rx="10" fill="{CORES["fundo"]}"/>',
        f'<rect width="{largura}" height="{BARRA}" rx="10" fill="{CORES["barra"]}"/>',
        f'<rect y="{BARRA - 10}" width="{largura}" height="10" fill="{CORES["barra"]}"/>',
    ]
    for i, cor in enumerate(("#ff5f56", "#ffbd2e", "#27c93f")):
        partes.append(f'<circle cx="{20 + i * 20}" cy="{BARRA / 2}" r="6" fill="{cor}"/>')
    partes.append(
        f'<text x="{largura / 2}" y="{BARRA / 2 + 5}" text-anchor="middle" '
        f'font-family="{FONTE}" font-size="13" fill="{CORES["titulo"]}">{html.escape(titulo)}</text>'
    )

    y = BARRA + MARGEM + TAMANHO
    for linha in linhas:
        atributos = f'x="{MARGEM}" y="{y}" font-family="{FONTE}" font-size="{TAMANHO}" xml:space="preserve"'
        if linha.startswith("$ "):
            partes.append(
                f'<text {atributos}><tspan fill="{CORES["prompt"]}">$ </tspan>'
                f'<tspan fill="{CORES["comando"]}">{html.escape(linha[2:])}</tspan></text>'
            )
        else:
            partes.append(f'<text {atributos} fill="{cor_da_linha(linha)}">{html.escape(linha)}</text>')
        y += ALTURA_LINHA

    partes.append("</svg>")
    return "\n".join(partes)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("entrada", type=Path)
    parser.add_argument("saida", type=Path)
    parser.add_argument("--titulo", default="cerqr@cachyos — k8s-lab")
    parser.add_argument("--linhas", type=int, default=45, help="máximo de linhas na imagem")
    parser.add_argument("--largura-max", type=int, default=200, help="corta linhas mais longas")
    args = parser.parse_args()

    linhas = args.entrada.read_text().expandtabs(8).rstrip("\n").splitlines()
    if len(linhas) > args.linhas:
        omitidas = len(linhas) - args.linhas
        linhas = [*linhas[: args.linhas], f"... ({omitidas} linhas omitidas; texto completo no .txt)"]
    linhas = [
        linha if len(linha) <= args.largura_max else linha[: args.largura_max - 1] + "…"
        for linha in linhas
    ]

    args.saida.parent.mkdir(parents=True, exist_ok=True)
    svg = gerar_svg(linhas, args.titulo)
    subprocess.run(
        ["rsvg-convert", "--zoom", "1.5", "-o", str(args.saida)], input=svg.encode(), check=True
    )
    print(args.saida)
    return 0


if __name__ == "__main__":
    sys.exit(main())
