import re, subprocess, sys
LLDB="/Library/Developer/CommandLineTools/usr/bin/lldb"
def run(cmds):
    open("c.txt","w").write("\n".join(["run"]+cmds)+"\n")
    return subprocess.run([LLDB,"-b","-s","c.txt","./t"],capture_output=True,text=True,timeout=170).stdout
methods=sys.argv[1:]
out=run([f'disassemble -n "{m}"' for m in methods])
body=out.split("(lldb) disassemble",1)[1] if "(lldb) disassemble" in out else out
targets=sorted(set(re.findall(r'\bbl\s+(0x[0-9a-f]+)',body)))
o2=run([f'disassemble -s {t} -c 3' for t in targets])
sel={}; reads=[]
for t in targets:
    m=re.search(re.escape(t)+r':\s+adrp\s+x1, (-?\d+)\n\s+0x[0-9a-f]+:\s+add\s+x1, x1, #(0x[0-9a-f]+)',o2)
    if m:
        a=(int(t,16)&~0xfff)+int(m.group(1))*0x1000+int(m.group(2),16)
        reads.append((t,a))
o3=run([f'expr -- (const char*)0x{a:x}' for t,a in reads])
vals=re.findall(r'\$\d+ = 0x[0-9a-f]+ "(.*)"',o3)
sel=dict(zip([t for t,a in reads],vals))
def sub(m):
    t=m.group(1); return f'bl      [{sel[t]}]' if t in sel else m.group(0)
res=re.sub(r'bl\s+(0x[0-9a-f]+)',sub,body)
print(res)
