import re, subprocess, sys
LLDB="/Library/Developer/CommandLineTools/usr/bin/lldb"
def run(cmds):
    open("c2.txt","w").write("\n".join(["run"]+cmds)+"\n")
    return subprocess.run([LLDB,"-b","-s","c2.txt","./t"],capture_output=True,text=True,timeout=300).stdout
methods=sys.argv[1:]
out=run([f'disassemble -n "{m}"' for m in methods])
body=out.split("(lldb) disassemble",1)[1]
targets=sorted(set(re.findall(r'\bbl\s+(0x[0-9a-f]+)',body)))
o2=run([f'disassemble -s {t} -c 3' for t in targets])
sel={}; sels=[]; gots=[]
for t in targets:
    m=re.search(re.escape(t)+r':\s+adrp\s+x1, (-?\d+)\n\s+0x[0-9a-f]+:\s+add\s+x1, x1, #(0x[0-9a-f]+)',o2)
    if m: sels.append((t,(int(t,16)&~0xfff)+int(m.group(1))*0x1000+int(m.group(2),16))); continue
    m=re.search(re.escape(t)+r':\s+adrp\s+x17, (-?\d+)\n\s+0x[0-9a-f]+:\s+add\s+x17, x17, #(0x[0-9a-f]+)',o2)
    if m: gots.append((t,(int(t,16)&~0xfff)+int(m.group(1))*0x1000+int(m.group(2),16)))
cmds=[f'expr -- (const char*)0x{a:x}' for t,a in sels]+[f'expr -- (unsigned long)(*(unsigned long*)0x{a:x} & 0x0000ffffffffffff)' for t,a in gots]
o3=run(cmds)
sv=re.findall(r'\(const char \*\) \$\d+ = 0x[0-9a-f]+ "(.*)"',o3)
pv=re.findall(r'\(unsigned long\) \$\d+ = (\d+)',o3)
for (t,a),v in zip(sels,sv): sel[t]="["+v+"]"
o4=run([f'image lookup -a {p}' for p in pv])
sy=re.findall(r'Summary: (.*)',o4)
# image lookup may print fewer entries on failure; map conservatively
if len(sy)==len(gots):
    for (t,a),s in zip(gots,sy): sel[t]=s.split("`")[-1]
def sub(m):
    t=m.group(1); return f'bl      {sel.get(t,t)}'
for line in re.sub(r'bl\s+(0x[0-9a-f]+)',sub,body).splitlines():
    if re.search(r'\bbl\b|; "|^\(lldb\)|`-\[',line): print(line.strip())
