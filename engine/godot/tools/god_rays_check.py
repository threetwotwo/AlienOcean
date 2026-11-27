# God rays check 0.1.0 (engine thread): numpy emulation of the Unreal god-ray node (ue_era lw/lagoonwater/logs/
# god_code_v53.txt + lagoonwater v98: GodPhys 1, GodUnits 1, GodPick 1, GodLod 0) on the map and the camera of
# tools/god_rays_check.gd, against the shader sum that tool wrote. float32 for the hashes and the jitter, as a GPU.
# Run: python3 tools/god_rays_check.py <dir> ["[sun_w x, y, z]" [steps [pick 0/1]]]   (env FR = frame 0..7 of the jitter)
# 28 Nov: hour 12 and 17, rms 0.0016 m against a sum of std 0.51 / 0.62 m (half-float buffer steps).
import numpy as np, sys
D=sys.argv[1]; W,H=960,540
img=np.frombuffer(open(D+"/acc.raw","rb").read(),np.float32).reshape(H,W,4)
mp=np.frombuffer(open(D+"/map.raw","rb").read(),np.float32).reshape(512,512,4)[...,:3].astype(np.float64)
print("map mean",mp.mean((0,1)),"std",mp.std((0,1)))
shader=(img[...,0].astype(np.float64)-0.5)/0.25
X=np.array([0.948683,0.0,0.316228]);Y=np.array([-0.256788,0.583609,0.770364]);Z=np.array([-0.184553,-0.812035,0.55366]);O=np.array([0.2,0.5,-8.6])
px,py=1.205,2.142222
sun_w=np.array(eval(sys.argv[2])) if len(sys.argv)>2 else np.array([-0.155973,0.987761,0.0])
water_y=4.0; VIS=15.0; N=int(sys.argv[3]) if len(sys.argv)>3 else 20; PICK=(sys.argv[4]!="0") if len(sys.argv)>4 else True
fr=lambda x:x-np.floor(x)
def tex(uv):
    p=uv*512-0.5; i=np.floor(p); f=p-i; i=i.astype(int)
    x0=i[...,0]%512;x1=(x0+1)%512;y0=i[...,1]%512;y1=(y0+1)%512; fx=f[...,0:1];fy=f[...,1:2]
    return (mp[y0,x0]*(1-fx)+mp[y0,x1]*fx)*(1-fy)+(mp[y1,x0]*(1-fx)+mp[y1,x1]*fx)*fy
def tbw(e,v):
    q=e/7.0+np.array([13.7,7.9])*v; i=np.floor(q); f=q-i; f=f*f*(3-2*f); a=np.array([127.1,311.7])
    f32=np.float32
    h=lambda o: fr((np.sin(((i+o).astype(f32)*a.astype(f32)).sum(-1,dtype=f32))*f32(43758.5453)).astype(f32)).astype(np.float64)
    m=(h([0,0])*(1-f[...,0])+h([1,0])*f[...,0])*(1-f[...,1])+(h([0,1])*(1-f[...,0])+h([1,1])*f[...,0])*f[...,1]
    t=np.clip((m-0.25)/0.5,0,1); return t*t*(3-2*t)+0.05
def x1(e): return np.stack([0.8*e[...,0]-0.6*e[...,1]+37.31,0.6*e[...,0]+0.8*e[...,1]+11.87],-1)
def x2(e): return np.stack([0.28*e[...,0]-0.96*e[...,1]+5.17,0.96*e[...,0]+0.28*e[...,1]+23.93],-1)
ys,xs=np.mgrid[0:H:4,0:W:4]
fx=xs+0.5; fy=ys+0.5
ndc_x=fx/W*2-1; ndc_y=-(fy/H*2-1)      # Godot SCREEN_UV y down; view y up
dv=np.stack([ndc_x/px,ndc_y/py,-np.ones_like(ndc_x)],-1); dv/=np.linalg.norm(dv,axis=-1,keepdims=True)
d=dv[...,0:1]*X+dv[...,1:2]*Y+dv[...,2:3]*Z
a=3.0/VIS; Lm=min(400.0,5.0/a); ds=Lm/N; seg=1-np.exp(-a*ds)
F=np.float32; t_=(fx.astype(F)*F(0.06711056)+fy.astype(F)*F(0.00583715)).astype(F); t_=t_-np.floor(t_); t_=(F(52.9829189)*t_).astype(F); import os; FRM=float(os.environ.get('FR','0')); t_=(t_-np.floor(t_)+F(FRM*0.618034)).astype(F); j=(t_-np.floor(t_)).astype(np.float64)
acc=np.zeros(fx.shape)
for i in range(N):
    s=(i+j)*ds; q=O+d*s[...,None]; dep=water_y-q[...,1]
    eg=q[...,[0,2]]+sun_w[[0,2]]*(dep/max(sun_w[1],0.2))[...,None]; e=np.stack([eg[...,0],-eg[...,1]],-1)
    u=np.clip(np.log2(np.maximum(dep,1e-3)/0.8)/1.321928,0,2)
    tb=np.stack([tbw(e,0),tbw(e,1),tbw(e,2)],-1); tb/=np.linalg.norm(tb,axis=-1,keepdims=True)
    Wt=tb.sum(-1)
    if PICK:
        r=fr(j*3.1123+i*0.5698403)*Wt
        pp=np.where((r<tb[...,0])[...,None],e,np.where((r<tb[...,0]+tb[...,1])[...,None],x1(e),x2(e)))
        cs=1+Wt[...,None]*(tex(pp/2.56)-1)
    else:
        cs=1+tb[...,0:1]*(tex(e/2.56)-1)+tb[...,1:2]*(tex(x1(e)/2.56)-1)+tb[...,2:3]*(tex(x2(e)/2.56)-1)
    cs=np.maximum(cs,0)
    c=np.where(u<1,cs[...,0]*(1-u)+cs[...,1]*u,cs[...,1]*(2-u)+cs[...,2]*(u-1))
    c=1+(c-1)*np.clip(dep/0.8,0,1)*np.clip(1.5-s*0.02,0,1)
    acc+=np.where(dep>0,np.exp(-a*s)*seg*(c-1),0)
acc/=a
sh=shader[::4,::4]
print("emu  mean %.4f std %.4f min %.3f max %.3f"%(acc.mean(),acc.std(),acc.min(),acc.max()))
print("shdr mean %.4f std %.4f min %.3f max %.3f"%(sh.mean(),sh.std(),sh.min(),sh.max()))
df=sh-acc; print("diff rms %.5f max %.4f  corr %.5f"%(np.sqrt((df**2).mean()),np.abs(df).max(),np.corrcoef(sh.ravel(),acc.ravel())[0,1]))
np.save(D+"/emu_acc%s.npy"%os.environ.get("FR","0"),acc)
