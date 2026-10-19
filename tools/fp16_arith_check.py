#!/usr/bin/env python3
"""Simulator-free check of the FP16 arithmetic in 06_2_programmer.v.

The functions below are a line-by-line Python transliteration of
fp16_pkg::fp16_mul / fp16_add (06_2_programmer.v).  They are compared with
numpy.float16 (the arithmetic used by assests/test.py, MODE="fp16") on
  * ~190k directed edge pairs (zeros, subnormals, exponent boundaries),
  * ~150k random pairs, and
  * a full replay of the supplied network with the transliterated arithmetic.

Usage (from the repository root):   python3 tools/fp16_arith_check.py
If you change the arithmetic in the RTL, update this transliteration too.
This is NOT a substitute for running the Verilog testbenches with iverilog.
"""
import os, random, sys
import numpy as np
# ---- transliteration of fp16_pkg ----
E=13
def isnan(x): return ((x>>10)&31)==31 and (x&0x3ff)!=0
def isinf(x): return ((x>>10)&31)==31 and (x&0x3ff)==0
def rsh(v,sh):
    if sh<=0: return v
    if sh>=63: return int(v!=0)
    return (v>>sh)|int((v&((1<<sh)-1))!=0)
def rnd(work, sh=E):
    ms=work>>sh; g=(work>>(sh-1))&1; r=(work>>(sh-2))&1; s=int((work&((1<<(sh-2))-1))!=0)
    if g and (r or s or (ms&1)): ms+=1
    return ms
def mul(a,b):
    sg=((a>>15)^(b>>15))&1
    if isnan(a) or isnan(b): return 0x7e00
    if (isinf(a) and (b&0x7fff)==0) or (isinf(b) and (a&0x7fff)==0): return 0x7e00
    if isinf(a) or isinf(b): return (sg<<15)|0x7c00
    if (a&0x7fff)==0 or (b&0x7fff)==0: return sg<<15
    def dec(x):
        if (x>>10)&31==0:
            m=x&0x3ff; e=-14
            j=0
            while j<13 and m<1024: m<<=1; e-=1; j+=1
            return m,e
        return 1024+(x&0x3ff), ((x>>10)&31)-15
    ma,ea=dec(a); mb,eb=dec(b)
    ex=ea+eb; prod=ma*mb
    if prod>=(1<<21): sig=prod<<2; ex+=1
    else: sig=prod<<3
    work=sig
    if ex<-14:
        work=rsh(work,-14-ex)
        ms=rnd(work)
        if ms>=1024: return (sg<<15)|0x0400
        return (sg<<15)|(ms&0x3ff)
    ms=rnd(work)
    if ms>=2048: ms>>=1; ex+=1
    if ex>15: return (sg<<15)|0x7c00
    return (sg<<15)|((ex+15)<<10)|((ms-1024)&0x3ff)
def add(a,b):
    if isnan(a) or isnan(b): return 0x7e00
    if isinf(a) and isinf(b) and (a>>15)!=(b>>15): return 0x7e00
    if isinf(a): return a
    if isinf(b): return b
    if (a&0x7fff)==0 and (b&0x7fff)==0: return ((a>>15)&(b>>15))<<15
    if (a&0x7fff)==0: return b
    if (b&0x7fff)==0: return a
    if ((a>>10)&31)==0 and ((b>>10)&31)==0:
        if (a>>15)==(b>>15):
            s=(a&0x3ff)+(b&0x3ff)
            return ((a>>15)<<15)|(0x0400+(s-1024) if s>=1024 else s)
        if (a&0x3ff)>(b&0x3ff): return ((a>>15)<<15)|((a&0x3ff)-(b&0x3ff))
        if (b&0x3ff)>(a&0x3ff): return ((b>>15)<<15)|((b&0x3ff)-(a&0x3ff))
        return 0
    sa=a>>15; sb=b>>15
    def dec(x):
        if (x>>10)&31==0:
            m=x&0x3ff; e=-14; j=0
            while j<13 and m!=0 and m<1024: m<<=1; e-=1; j+=1
            return m,e
        return 1024+(x&0x3ff), ((x>>10)&31)-15
    ma,ea=dec(a); mb,eb=dec(b)
    siga=ma<<E; sigb=mb<<E
    if ea>eb: ex=ea; sigb=rsh(sigb,ea-eb)
    else: ex=eb; siga=rsh(siga,eb-ea)
    def finish(sv,sigsum,ex):
        work=sigsum
        if ex<-14:
            work=rsh(work,-14-ex); ms=rnd(work)
            if ms>=1024: return (sv<<15)|0x0400
            return (sv<<15)|(ms&0x3ff)
        ms=rnd(work)
        if ms>=2048: ms>>=1; ex+=1
        if ex>15: return (sv<<15)|0x7c00
        return (sv<<15)|((ex+15)<<10)|((ms-1024)&0x3ff)
    if sa==sb:
        sv=sa; sm=siga+sigb
        if sm>=(2048<<E): sm=rsh(sm,1); ex+=1
        return finish(sv,sm,ex)
    if ea>eb or (ea==eb and ma>=mb): sv=sa; sm=siga-sigb
    else: sv=sb; sm=sigb-siga
    if sm==0: return 0
    j=0
    while j<40 and sm<(1024<<E) and ex>-40: sm<<=1; ex-=1; j+=1
    return finish(sv,sm,ex)


# ---------------------------------------------------------------- checks
ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assests")
f16 = lambda u: np.array([u], dtype=np.uint16).view(np.float16)[0]
u16 = lambda f: int(np.float16(f).view(np.uint16))
fin = lambda u: ((u >> 10) & 31) != 31

def rd(name):
    vals = [int(l.strip(), 16) for l in open(os.path.join(ASSETS, name)) if l.strip()]
    return np.array(vals, dtype=np.uint16).view(np.float16)

def compare(pairs, label):
    bad = 0
    for a, b in pairs:
        with np.errstate(all="ignore"):
            pm = u16(np.float16(f16(a) * f16(b))); pa = u16(np.float16(f16(a) + f16(b)))
        rm, ra = mul(a, b), add(a, b)
        if rm != pm or ra != pa:
            bad += 1
            if bad <= 5:
                print(f"  MISMATCH a={a:04x} b={b:04x} mul rtl={rm:04x} ref={pm:04x} add rtl={ra:04x} ref={pa:04x}")
    print(f"{label}: {len(pairs)} pairs, {bad} mismatches")
    return bad

def main():
    random.seed(7)
    bad = 0
    edge = (list(range(0, 0x40)) + list(range(0x8000, 0x8040)) +
            [0x03ff, 0x0400, 0x8400, 0x83ff, 0x3c00, 0xbc00, 0x7bff, 0xfbff] +
            [(s << 15) | (e << 10) | m for s in (0, 1) for e in range(1, 31) for m in (0, 1, 0x155, 0x2aa, 0x3ff)])
    bad += compare([(a, b) for a in edge for b in edge], "directed edge pairs")
    rnd = []
    while len(rnd) < 150000:
        a, b = random.getrandbits(16), random.getrandbits(16)
        if fin(a) and fin(b): rnd.append((a, b))
    bad += compare(rnd, "random finite pairs")

    W1 = rd("fc1_weights.mem").reshape(8, 784); b1 = rd("fc1_bias.mem")
    W2 = rd("fc2_weights.mem").reshape(10, 8);  b2 = rd("fc2_bias.mem")
    img = rd("test_image.mem")
    def mac(w, x, b):
        acc = u16(b)
        for p, v in zip(w, x): acc = add(acc, mul(u16(p), u16(v)))
        return acc
    fc1 = [mac(W1[n], img, b1[n]) for n in range(8)]
    hid = [0 if (v >> 15) else v for v in fc1]
    out = [mac(W2[d], [f16(h) for h in hid], b2[d]) for d in range(10)]
    exp = "411b c2bb 4844 43eb cd2b 43e8 444e caa1 3310 cad4".split()
    got = [f"{v:04x}" for v in out]
    print("replay logits :", " ".join(got))
    print("expected (tb) :", " ".join(exp))
    best = 0
    for i in range(1, 10):
        a, b = out[i], out[best]
        gt = ((not a >> 15) and (b >> 15)) if (a >> 15) != (b >> 15) else \
             ((a & 0x7fff) > (b & 0x7fff) if not a >> 15 else (a & 0x7fff) < (b & 0x7fff))
        if gt: best = i
    print("prediction    :", best, "(expected 2)")
    if got != exp or best != 2: bad += 1
    print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
