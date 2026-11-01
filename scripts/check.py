#!/usr/bin/env python3
"""ตรวจโค้ดก่อน deploy: syntax ของ Code.gs + สคริปต์ใน Index.html, มี doGet,
และฟังก์ชันใน API_FUNCS_ ต้องมีอยู่จริง / ฟังก์ชันที่หน้าเว็บเรียกต้องอยู่ใน API_FUNCS_"""
import re, subprocess, sys, tempfile, os

def die(msg):
    print('❌', msg); sys.exit(1)

code = open('Code.gs', encoding='utf-8').read()
html = open('Index.html', encoding='utf-8').read()

def node_check(src, name):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, name + '.js'); open(p, 'w', encoding='utf-8').write(src)
        r = subprocess.run(['node', '--check', p], capture_output=True, text=True)
        if r.returncode: die('Syntax error ใน ' + name + '\n' + r.stderr)

node_check(code, 'Code')
scripts = re.findall(r'<script>(.*?)</script>', html, re.S)
if not scripts: die('ไม่พบ <script> ใน Index.html')
node_check(max(scripts, key=len), 'Index-script')

if not re.search(r'^function doGet\s*\(', code, re.M): die('ไม่พบ function doGet')
m = re.search(r'const API_FUNCS_ = \{(.*?)\n\};', code, re.S)
if not m: die('ไม่พบ API_FUNCS_')
pairs = re.findall(r'^\s*(\w+):\s*(\w+)', m.group(1), re.M)
defs = set(re.findall(r'^function (\w+)', code, re.M))
missing = [b for a, b in pairs if b not in defs]
if missing: die('API_FUNCS_ อ้างฟังก์ชันที่ไม่มี: ' + ', '.join(missing))
api = {a for a, b in pairs}
used = set(re.findall(r"run\('(\w+)'", html))
bad = sorted(used - api)
if bad: die('หน้าเว็บเรียกฟังก์ชันที่ไม่อยู่ใน API_FUNCS_: ' + ', '.join(bad))
print('✅ ตรวจผ่าน: syntax ถูกต้อง, มี doGet, API ครบ (%d ฟังก์ชัน)' % len(pairs))
