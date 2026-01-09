#!/usr/bin/env python3
"""
Hunt Comparator - Compara estatisticas de monstros entre diferentes areas de hunt.

Uso:
    python3 scripts/hunt-comparator.py "Area1:monster1,monster2" "Area2:monster3,monster4"

Exemplo:
    python3 scripts/hunt-comparator.py \
        "Soul War:Bony Sea Devil,Brachiodemon,Branchy Crawler" \
        "Rotten Blood:Bloated Man-Maggots,Converters,Darklight Constructs"
"""

import os
import re
import sys
import glob
import argparse
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass

# Paths to search for monster files (tries each in order)
MONSTER_PATHS = [
    "data-global/monster",
    "data-otservbr-global/monster",
    "monster",
]

@dataclass
class MonsterStats:
    name: str
    hp: int
    xp: int
    max_melee: int
    max_spell: int
    file_path: str

def find_monster_file(monster_name: str, base_path: str) -> Optional[str]:
    """Find the .lua file for a monster by name."""
    # Convert monster name to possible file names
    # Try both with and without apostrophe
    file_name_no_apos = monster_name.lower().replace(" ", "_").replace("-", "-").replace("'", "")
    file_name_with_apos = monster_name.lower().replace(" ", "_").replace("-", "-")

    # Generate variations (singular/plural)
    variations = [file_name_no_apos, file_name_with_apos]
    for base in [file_name_no_apos, file_name_with_apos]:
        if base.endswith('s'):
            variations.append(base[:-1])  # Remove trailing 's'
        if base.endswith('es'):
            variations.append(base[:-2])  # Remove trailing 'es'
        if not base.endswith('s'):
            variations.append(base + 's')  # Add trailing 's'

    # Search recursively
    for path in MONSTER_PATHS:
        full_path = os.path.join(base_path, path)
        if not os.path.exists(full_path):
            continue

        for root, dirs, files in os.walk(full_path):
            for f in files:
                if f.endswith('.lua'):
                    # Check if file name matches any variation
                    f_base = f[:-4].lower()
                    for var in variations:
                        if f_base == var or f_base == var.replace("-", "_") or f_base == var.replace("_", "-"):
                            return os.path.join(root, f)

                    # Also check inside the file for the monster name
                    file_path = os.path.join(root, f)
                    try:
                        with open(file_path, 'r', encoding='utf-8', errors='ignore') as fp:
                            content = fp.read(500)  # Read first 500 chars
                            # Check for createMonsterType("Monster Name")
                            match = re.search(r'createMonsterType\s*\(\s*["\']([^"\']+)["\']', content)
                            if match:
                                found_name = match.group(1).lower()
                                if found_name == monster_name.lower():
                                    return file_path
                                # Check singular/plural
                                if found_name + 's' == monster_name.lower() or found_name == monster_name.lower() + 's':
                                    return file_path
                                if found_name.rstrip('s') == monster_name.lower().rstrip('s'):
                                    return file_path
                    except:
                        pass

    return None

def parse_monster_file(file_path: str) -> Optional[MonsterStats]:
    """Parse a monster .lua file and extract stats."""
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except:
        return None

    # Extract monster name (handle apostrophes in names like "Druid's Apparition")
    name_match = re.search(r'createMonsterType\s*\(\s*"([^"]+)"', content)
    if not name_match:
        # Try single quotes
        name_match = re.search(r"createMonsterType\s*\(\s*'([^']+)'", content)
    if not name_match:
        return None
    name = name_match.group(1)

    # Extract HP
    hp_match = re.search(r'monster\.health\s*=\s*(\d+)', content)
    hp = int(hp_match.group(1)) if hp_match else 0

    # Extract XP
    xp_match = re.search(r'monster\.experience\s*=\s*(\d+)', content)
    xp = int(xp_match.group(1)) if xp_match else 0

    # Extract max melee damage
    # Look for melee attack pattern
    melee_match = re.search(
        r'\{\s*name\s*=\s*["\']melee["\']\s*,.*?maxDamage\s*=\s*-?(\d+)',
        content,
        re.DOTALL
    )
    max_melee = int(melee_match.group(1)) if melee_match else 0

    # Extract max spell damage from ALL attacks (not just "combat")
    # Find all attacks in monster.attacks table and get their maxDamage
    attacks_section = re.search(r'monster\.attacks\s*=\s*\{(.*?)\n\}', content, re.DOTALL)
    max_spell = 0
    if attacks_section:
        attacks_content = attacks_section.group(1)
        # Find all maxDamage values in the attacks section (excluding melee)
        all_attacks = re.findall(
            r'\{\s*name\s*=\s*["\']([^"\']+)["\']\s*,.*?maxDamage\s*=\s*-?(\d+)',
            attacks_content,
            re.DOTALL
        )
        spell_damages = [int(dmg) for name, dmg in all_attacks if name.lower() != 'melee']
        max_spell = max(spell_damages) if spell_damages else 0

    return MonsterStats(
        name=name,
        hp=hp,
        xp=xp,
        max_melee=max_melee,
        max_spell=max_spell,
        file_path=file_path
    )

def format_number(n: int) -> str:
    """Format number with thousand separators."""
    return f"{n:,}".replace(",", ".")

def print_table(headers: List[str], rows: List[List[str]], title: str = ""):
    """Print a formatted table."""
    if title:
        print(f"\n{title}")

    # Calculate column widths
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))

    # Add padding
    widths = [w + 2 for w in widths]

    # Print header
    header_line = "|".join(f" {h:^{widths[i]-2}} " for i, h in enumerate(headers))
    separator = "+".join("-" * w for w in widths)

    print(f"+{separator}+")
    print(f"|{header_line}|")
    print(f"+{separator}+")

    # Print rows
    for row in rows:
        row_line = "|".join(f" {str(cell):^{widths[i]-2}} " for i, cell in enumerate(row))
        print(f"|{row_line}|")

    print(f"+{separator}+")

def analyze_hunt(name: str, monsters: List[str], base_path: str) -> Tuple[str, List[MonsterStats]]:
    """Analyze a hunt area and return stats for all monsters."""
    stats = []
    not_found = []

    for monster_name in monsters:
        monster_name = monster_name.strip()
        if not monster_name:
            continue

        file_path = find_monster_file(monster_name, base_path)
        if file_path:
            monster_stats = parse_monster_file(file_path)
            if monster_stats:
                stats.append(monster_stats)
            else:
                not_found.append(monster_name)
        else:
            not_found.append(monster_name)

    if not_found:
        print(f"\n[AVISO] Monstros nao encontrados em '{name}': {', '.join(not_found)}", file=sys.stderr)

    return name, stats

def main():
    parser = argparse.ArgumentParser(
        description='Compara estatisticas de monstros entre diferentes areas de hunt.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Exemplos:
  %(prog)s "Soul War:Bony Sea Devil,Brachiodemon" "Primal:Emerald Tortoise,Gore Horn"
  %(prog)s --file hunts.txt

Formato do arquivo:
  Soul War:Bony Sea Devil,Brachiodemon,Branchy Crawler
  Primal:Emerald Tortoise,Gore Horn,Gorerilla
        '''
    )
    parser.add_argument('hunts', nargs='*', help='Hunts no formato "Nome:monstro1,monstro2,..."')
    parser.add_argument('--file', '-f', help='Arquivo com lista de hunts (uma por linha)')
    parser.add_argument('--path', '-p', default='.', help='Caminho base do servidor (default: .)')

    args = parser.parse_args()

    # Collect hunt definitions
    hunt_defs = []

    if args.file:
        try:
            with open(args.file, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        hunt_defs.append(line)
        except FileNotFoundError:
            print(f"Erro: Arquivo '{args.file}' nao encontrado.", file=sys.stderr)
            sys.exit(1)

    hunt_defs.extend(args.hunts)

    if not hunt_defs:
        parser.print_help()
        sys.exit(1)

    # Parse hunt definitions
    hunts = []
    for hunt_def in hunt_defs:
        if ':' not in hunt_def:
            print(f"Erro: Formato invalido '{hunt_def}'. Use 'Nome:monstro1,monstro2,...'", file=sys.stderr)
            continue

        name, monsters_str = hunt_def.split(':', 1)
        monsters = [m.strip() for m in monsters_str.split(',')]
        hunts.append((name.strip(), monsters))

    if not hunts:
        print("Nenhuma hunt valida encontrada.", file=sys.stderr)
        sys.exit(1)

    # Analyze each hunt
    results = []
    for name, monsters in hunts:
        hunt_name, stats = analyze_hunt(name, monsters, args.path)
        if stats:
            results.append((hunt_name, stats))

    if not results:
        print("Nenhum monstro encontrado.", file=sys.stderr)
        sys.exit(1)

    # Print comparison header
    print("\n" + "=" * 70)
    print(f" Comparacao das Hunts: {' vs '.join(r[0] for r in results)}")
    print("=" * 70)

    # Calculate and print averages
    print("\n### Medias Gerais")
    avg_headers = ["Area", "HP Medio", "XP Medio", "Melee Max", "Spell Max", "XP/HP Ratio"]
    avg_rows = []

    base_hp = None
    base_xp = None
    base_melee = None
    base_spell = None

    for hunt_name, stats in results:
        avg_hp = sum(s.hp for s in stats) / len(stats)
        avg_xp = sum(s.xp for s in stats) / len(stats)
        avg_melee = sum(s.max_melee for s in stats) / len(stats)
        avg_spell = sum(s.max_spell for s in stats) / len(stats)
        ratio = avg_xp / avg_hp if avg_hp > 0 else 0

        if base_hp is None:
            base_hp = avg_hp
            base_xp = avg_xp
            base_melee = avg_melee
            base_spell = avg_spell

        avg_rows.append([
            hunt_name,
            format_number(int(avg_hp)),
            format_number(int(avg_xp)),
            format_number(int(avg_melee)),
            format_number(int(avg_spell)),
            f"{ratio:.2f}"
        ])

    print_table(avg_headers, avg_rows)

    # Print detailed stats for each hunt
    for hunt_name, stats in results:
        print(f"\n### {hunt_name}")

        # Sort by HP descending
        stats_sorted = sorted(stats, key=lambda s: s.hp, reverse=True)

        headers = ["Monstro", "HP", "XP", "Melee Max", "Spell Max"]
        rows = []
        for s in stats_sorted:
            rows.append([
                s.name,
                format_number(s.hp),
                format_number(s.xp),
                format_number(s.max_melee),
                format_number(s.max_spell)
            ])

        print_table(headers, rows)

    # Print hierarchy summary
    print("\n### Resumo da Hierarquia (vs primeira area)")

    if len(results) > 1:
        base_name, base_stats = results[0]
        base_hp = sum(s.hp for s in base_stats) / len(base_stats)
        base_xp = sum(s.xp for s in base_stats) / len(base_stats)
        base_melee = sum(s.max_melee for s in base_stats) / len(base_stats)

        summary_headers = ["Metrica"] + [r[0] for r in results]
        summary_rows = []

        # HP row
        hp_row = ["HP"]
        for hunt_name, stats in results:
            avg = sum(s.hp for s in stats) / len(stats)
            if hunt_name == base_name:
                hp_row.append(f"{avg/1000:.1f}k")
            else:
                diff = ((avg - base_hp) / base_hp) * 100
                hp_row.append(f"{avg/1000:.1f}k ({diff:+.0f}%)")
        summary_rows.append(hp_row)

        # XP row
        xp_row = ["XP"]
        for hunt_name, stats in results:
            avg = sum(s.xp for s in stats) / len(stats)
            if hunt_name == base_name:
                xp_row.append(f"{avg/1000:.1f}k")
            else:
                diff = ((avg - base_xp) / base_xp) * 100
                xp_row.append(f"{avg/1000:.1f}k ({diff:+.0f}%)")
        summary_rows.append(xp_row)

        # Melee row
        melee_row = ["Melee"]
        for hunt_name, stats in results:
            avg = sum(s.max_melee for s in stats) / len(stats)
            if hunt_name == base_name:
                melee_row.append(f"{int(avg)}")
            else:
                diff = ((avg - base_melee) / base_melee) * 100
                melee_row.append(f"{int(avg)} ({diff:+.0f}%)")
        summary_rows.append(melee_row)

        # Spell row
        spell_row = ["Spell"]
        for hunt_name, stats in results:
            avg = sum(s.max_spell for s in stats) / len(stats)
            if hunt_name == base_name:
                spell_row.append(f"{int(avg)}")
            else:
                diff = ((avg - base_spell) / base_spell) * 100 if base_spell > 0 else 0
                spell_row.append(f"{int(avg)} ({diff:+.0f}%)")
        summary_rows.append(spell_row)

        print_table(summary_headers, summary_rows)

    print()

if __name__ == '__main__':
    main()
