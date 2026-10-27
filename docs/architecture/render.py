#!/usr/bin/env python3
"""Render with Python stdlib + libfreetype; usage: python3 render.py /path/to/font.ttc"""
import ctypes as C
import ctypes.util
import math
import struct
import sys
import zlib
from pathlib import Path
from html import escape
W,H=1960,1740
pixels=bytearray(bytes.fromhex('f4f7fb')*(W*H))
svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}"><rect width="100%" height="100%" fill="#f4f7fb"/>']
ft=C.CDLL(ctypes.util.find_library('freetype'))
class Vec(C.Structure): _fields_=[('x',C.c_long),('y',C.c_long)]
class Bitmap(C.Structure): _fields_=[('rows',C.c_uint),('width',C.c_uint),('pitch',C.c_int),('buffer',C.POINTER(C.c_ubyte)),('num_grays',C.c_ushort),('pixel_mode',C.c_ubyte),('palette_mode',C.c_ubyte),('palette',C.c_void_p)]
class Generic(C.Structure): _fields_=[('data',C.c_void_p),('finalizer',C.c_void_p)]
class Slot(C.Structure): _fields_=[('library',C.c_void_p),('face',C.c_void_p),('next',C.c_void_p),('index',C.c_uint),('generic',Generic),('metrics',C.c_long*8),('linearHoriAdvance',C.c_long),('linearVertAdvance',C.c_long),('advance',Vec),('format',C.c_uint),('bitmap',Bitmap),('bitmap_left',C.c_int),('bitmap_top',C.c_int)]
class Face(C.Structure): _fields_=[('num_faces',C.c_long),('face_index',C.c_long),('face_flags',C.c_long),('style_flags',C.c_long),('num_glyphs',C.c_long),('family_name',C.c_char_p),('style_name',C.c_char_p),('num_fixed_sizes',C.c_int),('available_sizes',C.c_void_p),('num_charmaps',C.c_int),('charmaps',C.c_void_p),('generic',Generic),('bbox',C.c_long*4),('units_per_EM',C.c_ushort),('ascender',C.c_short),('descender',C.c_short),('height',C.c_short),('max_advance_width',C.c_short),('max_advance_height',C.c_short),('underline_position',C.c_short),('underline_thickness',C.c_short),('glyph',C.POINTER(Slot))]
lib=C.c_void_p(); assert ft.FT_Init_FreeType(C.byref(lib))==0
face=C.POINTER(Face)(); assert ft.FT_New_Face(lib,sys.argv[1].encode(),0,C.byref(face))==0
ft.FT_Get_Char_Index.argtypes=[C.POINTER(Face),C.c_ulong]
ft.FT_Load_Char.argtypes=[C.POINTER(Face),C.c_ulong,C.c_int32]
used=set()
def rgb(c): return bytes.fromhex(c.lstrip('#'))
def put(x,y,col,a=255):
 if 0<=x<W and 0<=y<H:
  i=(y*W+x)*3
  if a==255: pixels[i:i+3]=col
  elif a:
   for k in range(3): pixels[i+k]=(col[k]*a+pixels[i+k]*(255-a))//255

def rect(x,y,w,h,fill,stroke='#ced9e5'):
 col=rgb(fill); edge=rgb(stroke)
 for yy in range(y,y+h):
  pixels[(yy*W+x)*3:(yy*W+x+w)*3]=col*w
 for xx in range(x,x+w):
  put(xx,y,edge); put(xx,y+h-1,edge)
 for yy in range(y,y+h): put(x,yy,edge); put(x+w-1,yy,edge)
 svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="{stroke}"/>')
def text(x,y,s,size=24,color='#20334b'):
 ft.FT_Set_Pixel_Sizes(face,0,size); cursor=x
 for ch in s:
  used.add(ch); assert ft.FT_Get_Char_Index(face,ord(ch)), f'Missing glyph: {ch}'
  assert ft.FT_Load_Char(face,ord(ch),4)==0
  g=face.contents.glyph.contents; b=g.bitmap
  for yy in range(b.rows):
   for xx in range(b.width): put(cursor+g.bitmap_left+xx,y-g.bitmap_top+yy,rgb(color),b.buffer[yy*b.pitch+xx])
  cursor+=g.advance.x//64
 assert cursor<W-15,(s,cursor)
 svg.append(f'<text x="{x}" y="{y}" font-family="WenQuanYi Zen Hei, Noto Sans CJK TC, sans-serif" font-size="{size}" fill="{color}">{escape(s)}</text>')
def line(points,color='#3375b9',width=3,arrow=True):
 col=rgb(color)
 for (x1,y1),(x2,y2) in zip(points,points[1:]):
  n=max(abs(x2-x1),abs(y2-y1),1)
  for t in range(n+1):
   x=round(x1+(x2-x1)*t/n); y=round(y1+(y2-y1)*t/n)
   for dx in range(-width//2,width//2+1):
    for dy in range(-width//2,width//2+1): put(x+dx,y+dy,col)
 svg.append(f'<polyline points="{" ".join(f"{x},{y}" for x,y in points)}" fill="none" stroke="{color}" stroke-width="{width}"/>')
 if arrow:
  x,y=points[-1]; px,py=points[-2]; angle=math.atan2(y-py,x-px)
  for a in [angle-.5,angle+.5]: line([(round(x-14*math.cos(a)),round(y-14*math.sin(a))),(x,y)],color,width,False)
def box(x,y,w,h,title,lines,fill='#ffffff',color='#20334b'):
 assert len(lines) <= 1, 'Each box has at most two lines'
 rect(x,y,w,h,fill); text(x+22,y+40,title,30,color)
 for s in lines: text(x+22,y+80,s,27)

def dashed_container(x,y,w,h):
 # Use the same dash geometry for the raster and vector outputs.
 for start,end,fixed,horizontal in [
     (x,x+w,y,True),(x,x+w,y+h,True),
     (y,y+h,x,False),(y,y+h,x+w,False)]:
  for a in range(start,end,20):
   b=min(a+11,end)
   points=[(a,fixed),(b,fixed)] if horizontal else [(fixed,a),(fixed,b)]
   line(points,'#78909f',2,False)

def process_tag(x,y):
 text(x,y,'process',18,'#607586')

def process_box(x,y,w,title,role,fill,title_size=28):
 rect(x,y,w,130,fill)
 process_tag(x+w-90,y+23)
 text(x+20,y+59,title,title_size)
 text(x+20,y+103,role,25,'#435b70')

# Namespace, Pod and single-container boundaries.
text(50,75,'rdp-firefox｜系統運作架構',44)
rect(410,130,1500,1480,'#eaf1f9','#93adc7')
text(440,178,'Kubernetes 叢集',32)
rect(440,350,1440,1010,'#f8fbff','#9fb9d3')
text(1240,390,'namespace：web-workspace',30)
rect(470,535,1380,795,'#ffffff','#6e98bf')
text(1240,578,'rdp-firefox Pod',32)
dashed_container(495,595,1330,720)
text(1240,639,'container：desktop（單一 container）',27)
text(1240,676,'ghcr.io/braveantony/rdp-firefox:3.7-share',22,'#596e85')
rect(440,1410,1440,170,'#f8fbff','#9fb9d3')
text(470,1455,'namespace：taroko',30)

box(40,220,320,110,'Windows mstsc',['Mac Windows App'])
text(48,373,'連入即是 Firefox 桌面',26,'#3375b9')
box(470,220,420,110,'叢集節點（node）',['NodePort :30389'])
box(520,410,450,100,'Service：firefox-rdp',['30389 → 3389'])
box(1240,410,540,100,'Secret',['/etc/firefox-rdp/users'],'#fff7e9')
process_box(520,610,460,'① xrdp :3389／xrdp-sesman',
            '驗證帳號、開新桌面或轉給分享','#edf5ff',27)
process_box(520,840,460,'③ x0vncserver × N  127.0.0.1:59xx',
            '把桌面分享給持有 PIN 的人','#f5effb',26)
# A session contains its browser and desktop helper processes.
rect(1140,800,640,300,'#eef8f4')
process_tag(1680,823)
text(1162,850,'② Xorg session × N',30)
text(1162,889,'每條連線一個獨立桌面',25,'#435b70')
text(1162,919,'openbox · fcitx5 新酷音',22,'#596e85')
rect(1170,960,580,120,'#fff7ed','#dba46c')
rect(1184,972,552,28,'#ffffff','#e1c9af')
text(1196,993,'網址列',18,'#7b6a59')
process_tag(1650,993)
text(1195,1038,'Firefox 瀏覽器（全螢幕）',34,'#824617')
text(1195,1067,'使用者操作的畫面',22,'#7b6a59')
line([(1460,927),(1460,960)],width=5)
text(540,1115,'ttyd：僅監聽 loopback',26,'#298b88')
process_box(520,1170,580,'④ ttyd :2200',
            'bash 終端機（多帳號時先登入）','#edf8f8',30)
process_box(1140,1170,640,'⑤ ttyd :2210',
            'SSH 終端機 → tkadm（多帳號時詢問帳號）','#edf8f8',30)
box(1220,1470,560,100,'叢集管理 Pod：tkadm',['tkadm.taroko :22100'],'#edf8f8')

# Main route, account provisioning and sharing occupy separate corridors.
line([(360,275),(470,275)],width=5)
text(418,252,'RDP',25)
line([(680,330),(680,410)],width=5)
line([(700,510),(700,610)],width=5)
line([(980,710),(1040,710),(1040,850),(1140,850)],width=5)
text(1060,779,'開新桌面',25,'#3375b9')
line([(1240,460),(1100,460),(1100,660),(980,660)],'#b78a3f')
text(1010,640,'帳號',25,'#b78a3f')
line([(700,740),(700,840)],'#8753a6')
text(725,798,'join10～19 + PIN',25,'#8753a6')
line([(980,925),(1140,925)],'#8753a6')
text(1000,963,'共用畫面',25,'#8753a6')
# Each loopback listener has its own HTTP route from Firefox.
line([(1220,1080),(1220,1120),(800,1120),(800,1170)],'#298b88')
text(825,1155,'http://localhost:2200',26,'#298b88')
line([(1500,1080),(1500,1170)],'#298b88')
text(1520,1145,'http://localhost:2210',26,'#298b88')
line([(1540,1300),(1540,1470)],'#298b88')
text(1565,1395,'SSH',27,'#298b88')
text(440,1660,'粗藍：Firefox 桌面主路徑　 綠：HTTP／SSH　 紫：PIN 分享　 金：帳號',27,'#596e85')
text(440,1705,'虛線框 = container，內部方塊 = process',27,'#596e85')
out=Path(__file__).resolve().parent
svg.append('</svg>'); (out/'rdp-firefox-architecture.svg').write_text('\n'.join(svg))
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
raw=b''.join(b'\0'+pixels[y*W*3:(y+1)*W*3] for y in range(H))
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',W,H,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b'')
(out/'rdp-firefox-architecture.png').write_bytes(png)
print(f'PNG {W}x{H}: {len(png)} bytes; verified {len(used)} glyphs; font: {face.contents.family_name.decode()}')
