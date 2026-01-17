#!/usr/bin/env python3
import os
import re
import sys
from typing import Dict, Set, List, Tuple

# configuration
# -----------------------------------------------------------------------------
ANSI_RESET = "\033[0m"
ANSI_RED = "\033[31m"
ANSI_GREEN = "\033[32m"
ANSI_YELLOW = "\033[33m"
ANSI_CYAN = "\033[36m"
ANSI_BOLD = "\033[1m"

def success(msg): print(f"{ANSI_GREEN}✔ {msg}{ANSI_RESET}")
def warn(msg): print(f"{ANSI_YELLOW}⚠ {msg}{ANSI_RESET}")
def error(msg): print(f"{ANSI_RED}✘ {msg}{ANSI_RESET}")
def info(msg): print(f"{ANSI_CYAN}ℹ {msg}{ANSI_RESET}")
def bold(msg): return f"{ANSI_BOLD}{msg}{ANSI_RESET}"

class LocFile:
    def __init__(self, path: str, language: str):
        self.path = path
        self.language = language
        self.kv_map: Dict[str, str] = {}
        self.line_map: Dict[str, int] = {}
        self.errors: List[str] = []
        self.warnings: List[str] = []
        self.parse()

    def parse(self):
        if not os.path.exists(self.path):
            self.errors.append("File not found.")
            return

        with open(self.path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        # Regex for a valid line: "Key" = "Value";
        # We process line by line to catch syntax errors that a global regex would skip
        valid_line_pattern = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*(//.*)?$')
        comment_pattern = re.compile(r'^\s*(/\*|//|\*)')
        empty_pattern = re.compile(r'^\s*$')

        for i, line in enumerate(lines):
            lineno = i + 1
            line_stripped = line.strip()
            
            if empty_pattern.match(line):
                continue
            if comment_pattern.match(line_stripped):
                continue
                
            match = valid_line_pattern.match(line)
            if match:
                key = match.group(1)
                value = match.group(2)
                
                if key in self.kv_map:
                    self.errors.append(f"Line {lineno}: Duplicate key found: {bold(key)}")
                else:
                    self.kv_map[key] = value
                    self.line_map[key] = lineno
            else:
                # If it looks like a definition but failed regex, it's a syntax error
                if '"' in line and '=' in line:
                    self.errors.append(f"Line {lineno}: Malformed syntax. Check quotes or semicolon.\n      > {line_stripped}")

def get_placeholders(text: str) -> List[str]:
    # Matches %@, %d, %.2f, etc.
    return re.findall(r'%[0-9]*\.?[0-9]*[d@fs]', text)

def run_audit(project_root: str):
    print(bold("\n🛡️  PolarFlux Advanced Localization Audit"))
    print("=========================================")
    
    resources_dir = os.path.join(project_root, 'Resources')
    base_lang = 'en'
    base_path = os.path.join(resources_dir, f'{base_lang}.lproj', 'Localizable.strings')
    
    if not os.path.exists(base_path):
        error(f"Base language file not found at {base_path}")
        sys.exit(1)

    # Parse English Master
    master = LocFile(base_path, base_lang)
    if master.errors:
        error("Critical errors in English base file:")
        for e in master.errors: print(f"  {e}")
        sys.exit(1)
        
    info(f"Loaded Master ({base_lang}): {len(master.kv_map)} keys.")
    
    # Find targets
    lproj_dirs = [d for d in os.listdir(resources_dir) if d.endswith('.lproj') and d != 'en.lproj']
    lproj_dirs.sort()
    
    global_issues = 0
    
    for lproj_dir in lproj_dirs:
        lang_code = lproj_dir.replace('.lproj', '')
        file_path = os.path.join(resources_dir, lproj_dir, 'Localizable.strings')
        
        print(f"\nProcessing {bold(lang_code)}...")
        target = LocFile(file_path, lang_code)
        
        # 1. Syntax Errors
        if target.errors:
            for e in target.errors:
                error(e)
            global_issues += len(target.errors)
            continue # validation meaningless if file is broken
            
        # 2. Key Mismatches
        master_keys = set(master.kv_map.keys())
        target_keys = set(target.kv_map.keys())
        
        missing = master_keys - target_keys
        extras = target_keys - master_keys
        
        if missing:
            warn(f"MISSING {len(missing)} translations:")
            for k in sorted(missing):
                print(f"  - {k}")
            global_issues += len(missing)
            
        if extras:
            warn(f"EXTRA (Obsolete) keys found ({len(extras)}):")
            for k in sorted(extras):
                print(f"  + {k}")
            # Extras are warnings, not errors usually, but let's count them
            
        # 3. Value Auditing
        common_keys = master_keys.intersection(target_keys)
        
        for k in common_keys:
            m_val = master.kv_map[k]
            t_val = target.kv_map[k]
            
            # A. Placeholder mismatch (CRITICAL: Can crash app)
            m_ph = get_placeholders(m_val)
            t_ph = get_placeholders(t_val)
            if sorted(m_ph) != sorted(t_ph):
                error(f"Placeholder mismatch for '{k}'")
                print(f"  Default: {m_val}")
                print(f"  {lang_code}: {t_val}")
                global_issues += 1
                
            # B. Untranslated content heuristics
            # Skip short values or numbers
            if len(m_val) > 4 and not m_val.isdigit():
                if m_val == t_val:
                    # Specific exemptions
                    # If language relies on latin script, some words are same (Audio, Hardware)
                    # For CJK, identical english text is almost always an issue
                    is_cjk = lang_code in ['zh-Hans', 'zh-Hant', 'ja', 'ko']
                    is_safe_word = m_val in ["PolarFlux", "CPU", "FPS", "Metal"]
                    
                    if is_cjk and not is_safe_word:
                         # We allow copyright notices to be same
                         if "Copyright" not in k and "LICENSE" not in k:
                            warn(f"Potentially untranslated: '{k}' = \"{t_val}\"")
    
    print("\n-----------------------------------------")
    if global_issues == 0:
        success("Audit Passed. All localizations are healthy.")
        sys.exit(0)
    else:
        error(f"Audit Failed with {global_issues} issues.")
        sys.exit(1)

if __name__ == "__main__":
    run_audit(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
