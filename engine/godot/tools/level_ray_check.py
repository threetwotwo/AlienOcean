"""Level-ray check 0.1.0 (engine thread): the level ray 2 m deep, computed offline from the ported water physics
(core/world/water_optics.gd numbers, look/water_physics.gdshaderinc w_glow) and pushed through the ported Unreal AgX
(look/agx_post.glsl, day path). Compare with tools/lagoon_shots.gd shot 08_level_ray (row at half height).
27 Nov 2026: noon gives L* 57.8 / sRGB (39, 151, 172); Godot renders 57.8 / (39, 152, 173), so the Godot chain is exact.
EV under water = the clock's 15.5 noon cap - 0.75 (STEADY_UNDER_AT) = 14.75."""
import numpy as np
a0=np.array([0.35,0.06,0.025]); cdom=0.03*np.array([0.05,0.21,0.76]); a=a0+cdom
b=np.array([0.0433,0.05,0.06])*0.40; bb=0.019; g=0.9; sand=np.array([0.55,0.52,0.45]); K=2.5
def run(elev, beam_h, sky, ev, white_k=5772.0, H=4.0, z0=2.0, L=400.0, dg=(1.0713,0.9914,0.8748)):
    zs=np.radians(90-elev); zw=np.arcsin(np.sin(zs)/1.333); muw=np.cos(zw)
    tr=np.array([np.sin(zw),np.cos(zw),0.0])
    es0=beam_h*0.97; ek0=sky*0.934
    Kd=(a+bb*b)/muw; Ku=(a+bb*b)/0.75; c=a+b
    Gf=lambda k,L:(1-np.exp(-np.clip(k*L,-60,60)))/k
    d=np.array([0.0,0.0,1.0])  # level, perpendicular to the sun's azimuth (ct small)
    Es=es0*np.exp(-Kd*z0)/muw; Ek=ek0*np.exp(-Ku*z0); EH=es0*np.exp(-Kd*H)+ek0*np.exp(-Ku*H); Eu=EH*sand*np.exp(-Ku*(H-z0))
    ct=d@tr; ph=(1-g*g)/(4*np.pi*(1+g*g-2*g*ct)**1.5); Wd=np.clip(0.5+0.548*0,0,1)
    nits=K*b*(Es*ph*Gf(c,L)+(Ek*Gf(c,L)*(1-Wd)+Eu*Gf(c,L)*Wd)/np.pi)
    exposure=2**1.2/(1.2*2**ev)
    col=nits*np.array(dg)*exposure
    # white balance white_k -> D65 (Bradford)
    T=white_k*6504/6500; wx=(-4.6070e9/T**3+2.9678e6/T**2+99.11/T+0.244063); wy=-3*wx*wx+2.87*wx-0.275
    R2X=np.array([[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]])
    BR=np.array([[0.8951,0.2664,-0.1614],[-0.7502,1.7135,0.0367],[0.0389,-0.0685,1.0296]])
    s=BR@np.array([wx/wy,1,(1-wx-wy)/wy]); dd=BR@np.array([0.95047,1,1.08883])
    col=np.maximum(np.linalg.inv(R2X)@(np.linalg.inv(BR)@((BR@(R2X@col))*(dd/s))),0)
    INSET=np.array([[0.842479062253094,0.0423282422610123,0.0423756549057051],[0.0784335999999992,0.878468636469772,0.0784336],[0.0792237451477643,0.0791661274605434,0.879142973793104]])
    OUT=np.array([[1.19687900512017,-0.0528968517574562,-0.0529716355144438],[-0.0980208811401368,1.15190312990417,-0.0980434501171241],[-0.0990297440797205,-0.0989611768448433,1.15107367264116]])
    x=col@INSET; lo=np.log2(0.18)-10; hi=np.log2(0.18)+6.5
    x=(np.clip(np.log2(np.maximum(x,1e-10)),lo,hi)-lo)/(hi-lo)
    x=15.5*x**6-40.14*x**5+31.96*x**4-6.868*x**3+0.4298*x**2+0.1191*x-0.00232
    lu=x@[0.2126,0.7152,0.0722]; x=np.maximum(x,0)**1.14; x=lu+1.16*(x-lu)
    lin=np.maximum(x@OUT,0)**2.2; Y=lin@[0.2126,0.7152,0.0722]
    srgb=np.where(lin<=0.0031308,lin*12.92,1.055*lin**(1/2.4)-0.055)
    return nits, round(116*np.cbrt(Y)-16,1), (np.clip(srgb,0,1)*255).round().astype(int)

if __name__ == "__main__":
    print("noon", run(78.0, 106316.55, 16029.71, 14.75))
