"""A/B test the actual legacy and shared-cache policies in one Release binary.

Provide the previous experiment's manifest to reuse exactly the same sampled
headwords. Dictionary paths and per-process logs stay under ignored target/.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import re
import statistics
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--corpus',type=Path,required=True)
parser.add_argument('--history',type=Path,required=True)
args=parser.parse_args()
ROOT=Path(__file__).resolve().parents[2]
EXE=ROOT/'target/release/examples/index_cache_benchmark.exe'
PRIVATE=ROOT/'target/cache-budget-benchmark'
RESULTS=ROOT/'benchmarks/index-cache-budget/results-20261014'
PRIVATE.mkdir(parents=True,exist_ok=True)
RESULTS.mkdir(parents=True,exist_ok=True)
entries=json.loads(args.corpus.read_text(encoding='utf-8'))
for e in entries:
    e['index']=e.get('original_index',e['index'])

def run(label,argv,budget):
    env=os.environ.copy();env['LUMALEX_INDEX_CACHE_BYTES']=str(budget)
    p=subprocess.run([str(EXE),*argv],env=env,capture_output=True,text=True,encoding='utf-8',timeout=180)
    (PRIVATE/f'{label}.tsv').write_text(p.stdout,encoding='utf-8')
    (PRIVATE/f'{label}.txt').write_text(p.stderr,encoding='utf-8')
    if p.returncode: raise RuntimeError(label+'\n'+p.stderr)
    match=re.search(r'shared_cache_usage IndexChunkCacheUsage \{ (.+) \}',p.stderr)
    if match:
        usage={k:int(v) for k,v in re.findall(r'(\w+): (\d+)',match[1])}
        assert usage['peak_bytes']<=budget and usage['resident_bytes']<=budget,(label,usage)
        usage.update(run=label)
        pools.append(usage)
    print(label,flush=True)
    return p.stdout

pools=[]
for trial in range(3):
    for i,e in enumerate(entries):
        for budget in ([0,64*1024*1024] if (trial+i)%2==0 else [64*1024*1024,0]):
            name='legacy' if budget==0 else 'shared'
            run(f'{name}{trial}-{e["id"]}', ['one',e['id'],e['path'],e['index'],e['query']],budget)
    for group in ['english','all']:
        selected=[e for e in entries if group=='all' or e['english']]
        manifest=PRIVATE/f'{group}.tsv'
        manifest.write_text('\n'.join(f'{e["id"]}\t{e["path"]}\t{e["index"]}' for e in selected),encoding='utf-8')
        for budget in ([0,64*1024*1024] if trial%2==0 else [64*1024*1024,0]):
            name='legacy' if budget==0 else 'shared'
            run(f'{name}{trial}-{group}', ['group',str(manifest),str(args.history)],budget)
        if trial==0:
            run(f'constrained-{group}', ['group',str(manifest),str(args.history)],8*1024*1024)

verification=[]
for e in entries:
    digests=[]
    for budget in [0,8*1024*1024,64*1024*1024]:
        output=run(f'verify-{budget}-{e["id"]}',['verify',e['id'],e['path'],e['index'],e['query']],budget)
        line=[line for line in output.splitlines() if line.startswith('verify\t')][0]
        _,_,_,count,digest=line.split('\t');assert int(count)==300
        digests.append(digest)
    assert len(set(digests))==1,e['id']
    verification.append(dict(id=e['id'],queries=300,variants=3,digest=digests[0],passed=True))

rows=[]
for file in sorted(PRIVATE.glob('*.tsv')):
    if not file.stem.startswith(('legacy','shared','constrained')):continue
    for row in csv.DictReader(file.open(encoding='utf-8'),delimiter='\t'):
        row['run']=file.stem;rows.append(row)

def export(name,values):
    with (RESULTS/name).open('w',encoding='utf-8',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(values[0]),delimiter='\t');w.writeheader();w.writerows(values)

def stat(policy,id,work,column='mean_us'):
    data=[float(r[column]) for r in rows if r['run'] in [f'{policy}{i}-{id}' for i in range(3)] and r['workload']==work]
    assert len(data)==3,(policy,id,work,data)
    return statistics.median(data)

summary=[]
for e in entries:
    id=e['id'];old=stat('legacy',id,'app_lookup_first');new=stat('shared',id,'app_lookup_first')
    summary.append(dict(id=id,title=e['title'],legacy_mean_us=old,shared_mean_us=new,
                        improvement_pct=(1-new/old)*100,
                        legacy_p95_us=stat('legacy',id,'app_lookup_first','p95_us'),
                        shared_p95_us=stat('shared',id,'app_lookup_first','p95_us')))
    for trial in range(3):
        for work in ['random_locate','random_full','prefix20','app_lookup_first','miss_locate','repeat_full']:
            matching=[r for r in rows if r['run'] in [f'legacy{trial}-{id}',f'shared{trial}-{id}'] and r['workload']==work]
            assert len(matching)==2 and len({(r['hits'],r['checksum']) for r in matching})==1,(id,trial,work)
export('measurements.tsv',rows);export('summary.tsv',summary);export('verification.tsv',verification);export('cache-usage.tsv',pools)
report=['LumaLex 有总预算的共享索引缓存：正式实现验证','',
        '桌面共享缓存总预算64MiB，移动端8MiB；每个独立索引的数据区最多16块，全池最多1024块。',
        '预算包含块缓冲区实际容量与保守计入的缓存元数据；已经被淘汰但仍在读取的块仍计入预算。',
        '数据按需装入；预算满或缓存表分配失败时不保留本次块，查词仍可完成。打开的索引使用独立编号，关闭时释放其缓存。',
        '匹配、二分查找、规范化、重复词头、别名解析、checksum策略和源词头验证均保持原有代码。磁盘索引格式与名称不变，无需重建。',
        '同一Release二进制，对照未配置缓存的原单块策略与正式共享池；16本词典，每本300固定词头，3轮新进程、交替顺序。',
        '复用原C盘应用索引与原F盘MDX。Windows文件缓存未清空。下面为3轮均值的中位数，测Rust核心，不含桥、WebView或应用结果LRU。','',
        '词典\t原均值ms\t共享池均值ms\t原P95ms\t共享池P95ms\t耗时降低']
for s in summary:
    report.append(f'{s["title"]}\t{s["legacy_mean_us"]/1000:.3f}\t{s["shared_mean_us"]/1000:.3f}\t{s["legacy_p95_us"]/1000:.3f}\t{s["shared_p95_us"]/1000:.3f}\t{s["improvement_pct"]:.1f}%')
report+=['','多词典串行完整查询，不是GUI显示延迟：']
for group in ['english','all']:
    old=stat('legacy',group,'group_queries');new=stat('shared',group,'group_queries')
    peak=max(p['peak_bytes'] for p in pools if re.fullmatch('shared[0-2]-'+group,p['run']))
    report.append(f'{group}：{old/1000:.3f} → {new/1000:.3f} ms，降低{(1-new/old)*100:.1f}%；缓存峰值预算{peak/2**20:.2f} MiB，未超过64MiB。')
report+=['','输出校验：16本×300查询×3策略 = 14400个组合查询，词头、正文、重复匹配编号、前缀和应用别名结果的64位FNV摘要全部一致。',
         '8MiB受限池也完成全部抽样与多词典查询，峰值均在预算内。',
         '缓存单元测试覆盖多线程、多owner、LRU、关闭释放、零预算、大块降级、仍在使用的淘汰块和单词典紧预算。单个索引缓存还限制在该词典打开时可用解析内存的1/8以内。',
         '原持久索引匹配与损坏回归用例均分别跑单块与共享池。原测试精确页内存断言在共享池填充后保持，未放宽匹配或损坏判断。',
         '初次整套回归发现3个已有Windows file URL用例在原main也失败；修正测试夹具中的URL斜杠格式后，完整解析器套件无需排除即可通过。生产URL解析逻辑未改。部分本地语料测试原本ignored。',
         '生产实现仅在codex/index-cache-budget分支；main代码、当前安装程序、用户设置与原词典索引未更改。未合并或发布。']
(RESULTS/'report.txt').write_text('\n'.join(report)+'\n',encoding='utf-8')
print('\n'.join(report),flush=True)
