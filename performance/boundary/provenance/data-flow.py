from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from matplotlib.lines import Line2D
import yaml
topology=Path('dv/config/topology/mesh_4x4_memory.yml')
cfg=yaml.safe_load(topology.read_text())
assert cfg['connections'][-1]['dst_idx']==[0,4,8,12]
orange,blue='#D97706','#2463A5'
fig,axes=plt.subplots(1,2,figsize=(12,5))
def arrow(ax,a,b,color,offset=0):
 x0,y0=a;x1,y1=b
 if y0==y1:
  sign=1 if x1>x0 else -1
  a=(x0+sign*.34,y0+offset);b=(x1-sign*.34,y1+offset)
 else:
  sign=1 if y1>y0 else -1
  a=(x0+offset,y0+sign*.28);b=(x1+offset,y1-sign*.28)
 ax.annotate('',xy=b,xytext=a,arrowprops=dict(arrowstyle='-|>',color=color,lw=1.6,mutation_scale=10))
for panel,ax in enumerate(axes):
 for y in range(4):
  for x in range(4):
   if x<3:ax.plot([x,x+1],[y,y],color='#ddd',lw=1,zorder=0)
   if y<3:ax.plot([x,x],[y,y+1],color='#ddd',lw=1,zorder=0)
   node=y*4+x
   target=panel==1 and node==15
   ax.add_patch(FancyBboxPatch((x-.32,y-.26),.64,.52,boxstyle='round,pad=.02',
       facecolor='#FFF2DC' if target else '#E8F0FA',edgecolor=orange if target else blue,lw=1.3,zorder=3))
   ax.text(x,y,'NI'+str(node),ha='center',va='center',fontsize=10,zorder=4)
 if panel==0:
  for y in range(4):
   ax.add_patch(FancyBboxPatch((-1.32,y-.26),.64,.52,boxstyle='round,pad=.02',facecolor='#EDF5EB',edgecolor='#52784D',lw=1.3))
   ax.text(-1,y,'M'+str(y),ha='center',va='center',fontsize=10)
   for x in range(-1,3):
    arrow(ax,(x+1,y),(x,y),orange,.10)
    arrow(ax,(x,y),(x+1,y),blue,-.10)
 else:
  for y in range(4):
   for x in range(3):arrow(ax,(x,y),(x+1,y),orange,.10)
  for y in range(3):arrow(ax,(3,y),(3,y+1),orange,.10)
  for x in range(3):arrow(ax,(x+1,3),(x,3),blue,-.10)
  for x in range(4):
   for y in range(3):arrow(ax,(x,y+1),(x,y),blue,-.10)
 ax.set_title('Memory reads' if panel==0 else 'Narrow reads',fontsize=13,pad=12)
 ax.legend([Line2D([0],[0],color=orange,lw=2),Line2D([0],[0],color=blue,lw=2)],
           ['REQ','DAT' if panel==0 else 'RSP'],loc='lower center',bbox_to_anchor=(.5,-.05),ncol=2,frameon=False)
 ax.set_xlim(-1.55 if panel==0 else -.55,3.55);ax.set_ylim(-.55,3.55);ax.set_aspect('equal');ax.axis('off')
fig.tight_layout()
root=Path('performance/boundary/figures');root.mkdir(parents=True,exist_ok=True)
for suffix in ('png','svg'):fig.savefig(str(root/('data-flow.'+suffix)),dpi=180,bbox_inches='tight')
print('Saved boundary data-flow PNG/SVG')
