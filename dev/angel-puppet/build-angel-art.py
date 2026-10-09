"""Original code-authored vector master. SVG and native JSON share every curve."""
import json, math, hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
shapes = []
gradients = {
    'skin': {'kind':'radial','center':[459,385],'radius':310,'stops':[{'at':0,'color':'#FFE9D3'},{'at':0.64,'color':'#F5C8A8'},{'at':1,'color':'#D99278'}]},
    'hair': {'kind':'linear','start':[340,170],'end':[710,570],'stops':[{'at':0,'color':'#A66439'},{'at':0.35,'color':'#784226'},{'at':1,'color':'#452B22'}]},
    'curl': {'kind':'radial','center':[390,228],'radius':500,'stops':[{'at':0,'color':'#C1834B'},{'at':0.35,'color':'#92552F'},{'at':1,'color':'#4F3026'}]},
    'robe': {'kind':'linear','start':[315,623],'end':[745,1010],'stops':[{'at':0,'color':'#FFFDF0'},{'at':0.52,'color':'#F8EDE8'},{'at':1,'color':'#C9B5D8'}]},
    'feather': {'kind':'linear','start':[512,470],'end':[512,850],'stops':[{'at':0,'color':'#FFFFFF'},{'at':0.65,'color':'#F8F4E8'},{'at':1,'color':'#DED8EB'}]},
    'hands': {'kind':'radial','center':[500,756],'radius':155,'stops':[{'at':0,'color':'#FFE1C6'},{'at':0.7,'color':'#F1BFA0'},{'at':1,'color':'#DAA086'}]},
    'gold': {'kind':'linear','start':[320,70],'end':[700,130],'stops':[{'at':0,'color':'#D3A344'},{'at':0.4,'color':'#FFF2AD'},{'at':0.65,'color':'#E7BF57'},{'at':1,'color':'#AE7730'}]},
    'opal': {'kind':'linear','start':[300,640],'end':[720,940],'stops':[{'at':0,'color':'#F6C7E1'},{'at':0.35,'color':'#CCEAF1'},{'at':0.68,'color':'#DDD2F6'},{'at':1,'color':'#F9DBB7'}]},
    'pearl': {'kind':'radial','center':[480,80],'radius':800,'stops':[{'at':0,'color':'#FFFFFF'},{'at':0.65,'color':'#FFF7E8'},{'at':1,'color':'#CCBDD4'}]},
    'iris': {'kind':'radial','center':[423,403],'radius':64,'stops':[{'at':0,'color':'#A27644'},{'at':0.5,'color':'#755435'},{'at':1,'color':'#3F3026'}]},
}

def path(id, group, d, fill, stroke=None, sw=1, opacity=1):
    import re
    tokens=re.findall(r'[MLQCZ]|-?\d+(?:\.\d+)?',d)
    counts={'M':2,'L':2,'Q':4,'C':6,'Z':0}; segments=[];i=0
    while i<len(tokens):
        op=tokens[i]; n=counts[op]; segments.append({'op':op,'v':[float(x) for x in tokens[i+1:i+n+1]]});i+=n+1
    s={'id':id,'group':group,'path':segments,'fill':fill}
    if stroke:s.update(stroke=stroke,strokeWidth=sw)
    if opacity!=1:s['opacity']=opacity
    shapes.append(s)

def ellipse(id,g,cx,cy,rx,ry,fill,stroke=None,sw=1,opacity=1):
    k=0.5522847498
    d=f'M {cx-rx} {cy} C {cx-rx} {cy-ry*k} {cx-rx*k} {cy-ry} {cx} {cy-ry} C {cx+rx*k} {cy-ry} {cx+rx} {cy-ry*k} {cx+rx} {cy} C {cx+rx} {cy+ry*k} {cx+rx*k} {cy+ry} {cx} {cy+ry} C {cx-rx*k} {cy+ry} {cx-rx} {cy+ry*k} {cx-rx} {cy} Z'
    path(id,g,d,fill,stroke,sw,opacity)

def star(id,g,cx,cy,r,fill,stroke=None):
    pts=[]
    for i in range(10):
        a=-math.pi/2+i*math.pi/5;rr=r if i%2==0 else r*0.46;pts.append((cx+math.cos(a)*rr,cy+math.sin(a)*rr))
    d='M '+' L '.join(f'{x:.3f} {y:.3f}' for x,y in pts)+' Z';path(id,g,d,fill,stroke,1.5)

# Plush feather layers sit behind the robe. Both tips have generous canvas margin.
for right in [False,True]:
    group='rightWing' if right else 'leftWing'; side='right' if right else 'left'
    def mirror(p):return [(1024-x if right else x,y) for x,y in p]
    # The explicit mirror preserves the exact original left-wing curves.
    for j,d in enumerate([
        'M 347 647 C 272 574 169 492 99 468 C 73 503 73 559 108 602 C 80 632 106 680 146 699 C 128 737 174 776 211 776 C 215 828 291 844 350 796 C 389 751 388 690 347 647 Z',
        'M 335 657 C 258 599 157 530 109 493 C 91 542 179 612 299 694 C 258 673 179 622 130 614 C 116 649 226 708 307 728 C 258 720 193 698 165 701 C 160 737 259 771 328 755 C 291 777 250 783 231 781 C 238 818 311 807 350 777 C 378 736 373 686 335 657 Z'
    ]):
        if right:
            import re
            ts=re.findall(r'[MLQCZ]|-?\d+(?:\.\d+)?',d);out=[];n=0
            for t in ts:
                if t.isalpha():out.append(t);n=0
                else:out.append(str(1024-float(t) if n%2==0 else float(t)));n+=1
            d=' '.join(out)
        path(f'{side}-feathers-{j}',group,d,'feather','#D4C9BA',2)
    # Small pearly down near each shoulder.
    for j,(x,y,r) in enumerate([(309,653,34),(330,698,35),(335,745,29)]):
        ellipse(f'{side}-down-{j}',group,1024-x if right else x,y,r,r*1.25,'pearl', '#E4DDD5',1)

# High-neck, long-sleeved robe, completely clothed; neck underpaint stays joined.
path('neck','body','M 447 572 L 577 572 L 587 686 Q 512 726 437 686 Z','skin')
path('robe','body','M 419 624 Q 512 663 605 624 C 670 627 733 687 751 791 L 794 1003 Q 512 1018 230 1003 L 273 791 C 291 687 354 627 419 624 Z','robe','#BDA9BC',3)
path('robe-left-fold','body','M 349 737 Q 301 858 299 1001','none','#DED0D8',7)
path('robe-right-fold','body','M 674 735 Q 721 853 726 1003','none','#D4C2D6',7)
path('robe-center-fold','body','M 512 811 Q 484 915 501 1007','none','#E4D6DF',6)
path('collar','body','M 416 623 Q 460 645 512 643 Q 564 645 608 623 L 626 673 Q 568 700 512 691 Q 456 700 398 673 Z','pearl','#D6C0CA',2)
for i in range(17):
    x=409+i*12.9;y=675+16*math.sin(i*math.pi/16)
    ellipse(f'collar-pearl-{i}','body',x,y,6,6,'pearl','#BEAFBC',0.8)

# Pastel opal embroidery and fixed jewel positions for restrained native glints.
for i,(x,y,r) in enumerate([(333,808,10),(361,917,8),(675,817,10),(651,930,8),(469,934,9),(561,966,8),(513,865,12)]):
    star(f'robe-jewel-{i}','body',x,y,r,'opal','#CFAC75')
for i,(x,y) in enumerate([(374,855),(337,946),(682,886),(707,955),(434,887),(599,881),(411,963),(613,985)]):
    ellipse(f'robe-sequin-{i}','body',x,y,4.5,4.5,'opal','#DAC9AF',0.8)
star('heart-star','body',512,731,29,'opal','#C79C59')
ellipse('heart-pearl','body',512,731,8,8,'pearl','#E8CEA5',1)
# Sleeves cradle small clasped hands without detached wrist seams.
path('sleeve-left','body','M 341 698 C 313 717 295 757 314 797 Q 361 836 440 807 L 472 764 Q 402 746 380 713 Z','robe','#CEBACB',2)
path('sleeve-right','body','M 683 698 C 711 717 729 757 710 797 Q 663 836 584 807 L 552 764 Q 622 746 644 713 Z','robe','#CEBACB',2)
path('left-hand','body','M 437 763 Q 456 746 482 747 L 525 753 Q 539 758 535 768 Q 531 774 516 771 L 490 768 Q 509 781 543 781 Q 555 784 551 795 Q 547 803 531 801 L 494 797 Q 465 801 443 792 Q 427 783 437 763 Z','hands','#CD927D',1.4)
path('right-hand','body','M 584 763 Q 569 751 549 752 L 513 766 Q 502 772 506 780 Q 510 785 520 782 L 544 773 Q 525 786 502 791 Q 490 795 494 804 Q 500 810 513 805 L 548 795 Q 571 794 584 782 Q 592 773 584 763 Z','hands','#CD927D',1.4)
path('fingers','body','M 452 777 Q 469 788 488 783 M 551 780 L 571 772','none','#CE9682',1.3)

# Warm round head, ears and a cloud of original chestnut curls.
ellipse('hair-underlay','head',512,389,235,234,'hair')
ellipse('ear-left','head',321,457,30,45,'skin','#D59B82',2)
ellipse('ear-right','head',703,457,30,45,'skin','#D59B82',2)
path('left-inner-ear','head','M 312 444 Q 334 444 326 474','none','#DAA087',3)
path('right-inner-ear','head','M 712 444 Q 690 444 698 474','none','#DAA087',3)
path('face','head','M 333 333 C 343 259 418 235 512 241 C 606 235 681 259 691 333 L 702 444 C 707 532 636 619 512 635 C 388 619 317 532 322 444 Z','skin','#C3876D',2.2)
for i,(x,y,rx,ry) in enumerate([(296,373,47,52),(286,424,38,44),(298,472,35,42),(326,507,29,37),(728,373,47,52),(738,424,38,44),(726,472,35,42),(698,507,29,37),(309,309,54,56),(349,254,62,58),(402,214,63,61),(468,200,57,54),(529,196,60,52),(588,206,60,54),(643,233,62,56),(692,285,58,60),(530,246,46,42),(455,257,39,35),(382,291,38,37),(622,286,35,38)]):
    ellipse(f'curl-{i}','head',x,y,rx,ry,'curl','#623C28',1.2)
    path(f'curl-shine-{i}','head',f'M {x-rx*.36:.3f} {y-ry*.33:.3f} Q {x:.3f} {y-ry*.65:.3f} {x+rx*.38:.3f} {y-ry*.25:.3f}','none','#C18A51',3,0.47)
    path(f'curl-coil-{i}','head',f'M {x+rx*.37:.3f} {y:.3f} C {x+rx*.3:.3f} {y+ry*.35:.3f} {x-rx*.22:.3f} {y+ry*.4:.3f} {x-rx*.28:.3f} {y+ry*.08:.3f} Q {x-rx*.28:.3f} {y-ry*.19:.3f} {x+rx*.09:.3f} {y-ry*.12:.3f}','none','#6F432B',2.2,0.4)
# Tiny pearl hair ornament, not a crown or adult makeup.
for i,(x,y,r) in enumerate([(639,298,6),(650,288,8),(664,293,5)]):ellipse(f'hair-pearl-{i}','head',x,y,r,r,'pearl','#CCA669',1)
path('nose','head','M 501 466 Q 509 448 520 466 Q 527 481 511 485 Q 500 484 501 477','skin','#DDA188',1.7)
ellipse('nose-light','head',509,467,6,3,'#FFEDD8',opacity=0.65)

# Detached jewel halo, airy gap above the curls. Pearl locations never jump.
ellipse('halo-outline','halo',512,99,153,25,'none','#AB7731',11)
ellipse('halo-gold','halo',512,96,153,25,'none','gold',8)
for i in range(20):
    a=2*math.pi*i/20;x=512+153*math.cos(a);y=96+25*math.sin(a)
    ellipse(f'halo-pearl-{i}','halo',x,y,5.5,5.5,'pearl','#C9A462',0.8)
star('halo-star','halo',512,71,13,'opal','#B68D45')

features={'eyes':[{'cx':423,'cy':416,'width':112,'height':126,'irisRadius':42},{'cx':601,'cy':416,'width':112,'height':126,'irisRadius':42}],
          'mouth':{'cx':512,'cy':549,'width':90,'height':72},
          'cheeks':[{'cx':372,'cy':507,'rx':41,'ry':23},{'cx':652,'cy':507,'rx':41,'ry':23}]}
spec={'schema':1,'canvas':1024,'name':'Angel','groups':['leftWing','rightWing','body','head','halo'],'pivots':{'head':[512,610],'body':[512,970],'leftWing':[342,682],'rightWing':[682,682],'halo':[512,96]},'gradients':gradients,'shapes':shapes,'features':features,
      'palette':{'eyeWhite':'#FFF9ED','irisLight':'#AA8350','irisDark':'#503A2A','pupil':'#261F20','eyeOutline':'#593929','brow':'#6A402A','cheek':'#EE9A9D','mouth':'#833F48','tongue':'#DC8A91','tooth':'#FFF5E2'},
      'description':'Angel is a tiny cherub girl with chestnut curls, big hazel eyes and rosy cheeks. She wears a high-neck ivory robe with pastel opals, pearl beads and jewel stars. Her little hands are clasped near her heart, white feathered wings frame her shoulders, and a pearl-studded gold halo floats above her curls.'}
json_path=ROOT/'angel-vector.json';json_path.write_text(json.dumps(spec,indent=2)+'\n',encoding='utf-8')

def paint(v):return 'url(#'+v+')' if v in gradients else v
def svg_shape(s):
    d=' '.join(seg['op']+' '+' '.join(f'{v:g}' for v in seg['v']) for seg in s['path'])
    return f'<path id="{s["id"]}" d="{d}" fill="{paint(s["fill"])}" stroke="{paint(s.get("stroke","none"))}" stroke-width="{s.get("strokeWidth",0)}" opacity="{s.get("opacity",1)}" stroke-linecap="round" stroke-linejoin="round"/>'
defs=[]
for id,g in gradients.items():
    if g['kind']=='linear':attrs=f'x1="{g["start"][0]}" y1="{g["start"][1]}" x2="{g["end"][0]}" y2="{g["end"][1]}"';tag='linearGradient'
    else:attrs=f'cx="{g["center"][0]}" cy="{g["center"][1]}" r="{g["radius"]}"';tag='radialGradient'
    stops=''.join(f'<stop offset="{s["at"]}" stop-color="{s["color"]}" stop-opacity="{s.get("opacity",1)}"/>' for s in g['stops'])
    defs.append(f'<{tag} id="{id}" gradientUnits="userSpaceOnUse" {attrs}>{stops}</{tag}>')
content=[]
for group in spec['groups']:
    content.extend(svg_shape(s) for s in shapes if s['group']==group)
    if group=='head':
        for i,c in enumerate(features['cheeks']):
            cx,cy=c['cx'],c['cy']-.5
            defs.append(f'<radialGradient id="cheek-{i}" gradientUnits="userSpaceOnUse" cx="{cx}" cy="{cy}" r="{c["rx"]}"><stop offset="0" stop-color="#EE9FA0" stop-opacity=".66"/><stop offset="1" stop-color="#EE9FA0" stop-opacity="0"/></radialGradient>')
            content.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{c["rx"]}" ry="{c["ry"]}" fill="url(#cheek-{i})" opacity=".592"/>')
        for i,e in enumerate(features['eyes']):
            x,y=e['cx'],e['cy'];r=e['irisRadius']
            w,h=e['width'],e['height']
            ep=f'M {x-w/2} {y} Q {x} {y-h*.92} {x+w/2} {y} Q {x} {y+h*.72} {x-w/2} {y} Z'
            defs.append(f'<clipPath id="eye-clip-{i}"><path d="{ep}"/></clipPath>')
            defs.append(f'<linearGradient id="eye-white-{i}" gradientUnits="userSpaceOnUse" x1="{x}" y1="{y-h/2}" x2="{x}" y2="{y+h/2}"><stop offset="0" stop-color="#FFFCF5"/><stop offset="1" stop-color="#EEE2D4"/></linearGradient>')
            defs.append(f'<radialGradient id="eye-iris-{i}" gradientUnits="userSpaceOnUse" cx="{x}" cy="{y+r*.1}" r="{r}"><stop offset="0" stop-color="#AE8644"/><stop offset=".5" stop-color="#756337"/><stop offset="1" stop-color="#40331E"/></radialGradient>')
            content.append(f'<path d="{ep}" fill="url(#eye-white-{i})"/>')
            content.append(f'<g clip-path="url(#eye-clip-{i})"><circle cx="{x}" cy="{y}" r="{r}" fill="url(#eye-iris-{i})"/><ellipse cx="{x}" cy="{y-r*.03}" rx="{r*.47}" ry="{r*.55}" fill="#251C17"/><ellipse cx="{x-r*.22}" cy="{y-r*.31}" rx="{r*.2}" ry="{r*.17}" fill="#FFFFFF" opacity=".95"/><ellipse cx="{x+r*.265}" cy="{y+r*.30}" rx="{r*.085}" ry="{r*.07}" fill="#FFF7DB" opacity=".75"/></g>')
            content.append(f'<path d="{ep}" fill="none" stroke="#805D43" opacity=".76" stroke-width="2.3"/><path d="M {x-w/2} {y} Q {x} {y-h*.92} {x+w/2} {y}" fill="none" stroke="#684735" stroke-width="4" stroke-linecap="round"/>')
            bx=w*.41;by=y-h*.72
            content.append(f'<path d="M {x-bx} {by} Q {x} {by-8} {x+bx} {by}" fill="none" stroke="#684126" stroke-width="6" stroke-linecap="round"/>')
        content.append('<path d="M 467 546.5 Q 512 561 557 546.5" fill="none" stroke="#AA6860" stroke-width="4" stroke-linecap="round"/>')
svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><title>Angel, original sparkly cherub puppet</title><defs>'+''.join(defs)+'</defs>'+''.join(content)+'</svg>'
(ROOT/'angel-master.svg').write_text(svg,encoding='utf-8')
(ROOT/'art-provenance.json').write_text(json.dumps({'kind':'original-code-authored-vector','master':'angel-master.svg','nativeGeometry':'angel-vector.json','generator':'build-angel-art.py','geometrySHA256':hashlib.sha256(json_path.read_bytes()).hexdigest(),'canvas':[1024,1024],'sourcePixelsFromOtherCharacters':False,'rasterExport':'SVG rasterization only; no raster image editing','imagegenArtworkCreated':False},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'shapes':len(shapes),'geometrySHA256':hashlib.sha256(json_path.read_bytes()).hexdigest(),'output':str(ROOT/'angel-master.svg')}))
