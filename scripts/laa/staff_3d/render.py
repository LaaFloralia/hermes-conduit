"""Render an LAA staff idle loop + stills from an existing GLB (headless Blender 5.x).

blender -b --factory-startup -P render.py -- --glb in.glb --out DIR --id ciel
        [--frames 60] [--size 512] [--hero 1024] [--only-frame N] [--hero-only] [--fix ROLL PITCH YAW]
Identical camera/lighting for every employee: framing is derived from the head
top and head x of each model, the rest is fixed. Breath and neck sway go through
the skeleton. A model without a skeleton gets a 4-bone height-weighted spine in
the render scene only (the source GLB is never written).
"""
import bpy, sys, math, argparse, json
from mathutils import Vector, Matrix, Quaternion

a = argparse.ArgumentParser()
a.add_argument('--glb'); a.add_argument('--out'); a.add_argument('--id')
a.add_argument('--frames', type=int, default=60); a.add_argument('--size', type=int, default=512)
a.add_argument('--hero', type=int, default=1024); a.add_argument('--only-frame', type=int, default=-1)
a.add_argument('--frame-h', type=float, default=0.62)   # metres covered by the frame height
a.add_argument('--samples', type=int, default=64)
a.add_argument('--hero-frame-h', type=float, default=0.66)
a.add_argument('--hero-only', action='store_true')
a.add_argument('--light', type=float, nargs=3, default=[34, 10, 30])
a.add_argument('--world', type=float, default=0.12)
a.add_argument('--fix', type=float, nargs=3, default=None, help='head roll pitch yaw (deg); roll defaults to auto level')
args = a.parse_args(sys.argv[sys.argv.index('--') + 1:])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=args.glb)
sc = bpy.context.scene

meshes = [o for o in sc.objects if o.type == 'MESH']
for o in meshes:  # stray helper objects shipped in the rigged GLBs
    if o.name.startswith('Icosphere'):
        o.hide_render = True; o.hide_viewport = True
meshes = [o for o in meshes if not o.hide_render]
arm = next((o for o in sc.objects if o.type == 'ARMATURE'), None)

def world_verts(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    for o in objs:
        e = o.evaluated_get(dg); m = e.to_mesh()
        for v in m.vertices: yield e.matrix_world @ v.co
        e.to_mesh_clear()

pts = list(world_verts(meshes))
ztop = max(p.z for p in pts)
rigged = arm is not None
if not rigged:
    # Render-scene skeleton: Root(hips) > Chest > Neck > Head, weights by height bands.
    zmin = min(p.z for p in pts)
    hgt = ztop - zmin
    face = [p for p in pts if p.z > ztop - 0.12 * hgt]
    hx = sum(p.x for p in face) / len(face)
    z_hip, z_chest, z_neck, z_head = zmin + .53 * hgt, zmin + .72 * hgt, zmin + .815 * hgt, zmin + .855 * hgt
    ad = bpy.data.armatures.new('render_rig'); arm = bpy.data.objects.new('render_rig', ad)
    sc.collection.objects.link(arm); bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    chain = [('Spine02', z_hip, z_chest), ('Spine', z_chest, z_neck), ('neck', z_neck, z_head), ('Head', z_head, ztop)]
    prev = None
    for n, z0, z1 in chain:
        b = ad.edit_bones.new(n); b.head = (hx, 0, z0); b.tail = (hx, 0, z1)
        if prev: b.parent = prev; b.use_connect = True
        prev = b
    bpy.ops.object.mode_set(mode='OBJECT')
    def smooth(z, a0, a1):
        t = min(max((z - a0) / (a1 - a0), 0), 1); return t * t * (3 - 2 * t)
    for o in meshes:
        groups = {n: o.vertex_groups.new(name=n) for n, *_ in chain}
        mw = o.matrix_world
        for v in o.data.vertices:
            z = (mw @ v.co).z
            wh = smooth(z, z_head - .02 * hgt, z_head + .02 * hgt)
            wn = smooth(z, z_neck - .02 * hgt, z_neck + .02 * hgt) - wh
            wc = smooth(z, z_chest - .05 * hgt, z_chest + .05 * hgt) - wn - wh
            ws = 1 - wc - wn - wh
            for n, w in (('Spine02', ws), ('Spine', wc), ('neck', wn), ('Head', wh)):
                if w > 1e-4: groups[n].add([v.index], w, 'REPLACE')
        mod = o.modifiers.new('rig', 'ARMATURE'); mod.object = arm
else:
    arm.animation_data_clear()
    for o in meshes:
        if o.animation_data: o.animation_data_clear()

pb = arm.pose.bones
for p in pb:
    p.rotation_mode = 'QUATERNION'; p.rotation_quaternion = (1, 0, 0, 0); p.location = (0, 0, 0); p.scale = (1, 1, 1)
bpy.context.view_layer.update()
bx = lambda n: (arm.matrix_world @ arm.data.bones[n].head_local).x
head_x = bx('Head')
if 'LeftArm' in arm.data.bones and 'RightArm' in arm.data.bones:
    head_x = 0.5 * head_x + 0.25 * (bx('LeftArm') + bx('RightArm'))  # balance face and shoulders
# Portrait correction: level the head (auto roll from Head->head_end) and lift the gaze.
roll, pitch, yaw = 0.0, -8.0, 0.0
if 'head_end' in arm.data.bones:
    d = arm.data.bones['head_end'].head_local - arm.data.bones['Head'].head_local
    roll = math.degrees(math.atan2(-d.x, d.z))
if args.fix: roll, pitch, yaw = (args.fix[0] if args.fix[0] != 999 else roll), args.fix[1], args.fix[2]
print('FIX', round(roll, 2), pitch, yaw)

# ---- camera: one orthographic framing rule for all ----
H = args.frame_h
top = ztop + 0.08 * H
cz = top - H / 2
cam_d = bpy.data.cameras.new('cam'); cam_d.type = 'ORTHO'; cam_d.ortho_scale = H
cam = bpy.data.objects.new('cam', cam_d); sc.collection.objects.link(cam); sc.camera = cam
cam.location = (head_x, -3.0, cz); cam.rotation_euler = (math.radians(90), 0, 0)

# ---- light: soft key upper-left, warm fill right, cool rim behind (reads on paper, teal, ink) ----
def area(name, loc, energy, size, color, target):
    d = bpy.data.lights.new(name, 'AREA'); d.energy = energy; d.size = size; d.color = color
    o = bpy.data.objects.new(name, d); sc.collection.objects.link(o); o.location = loc
    dvec = Vector(target) - Vector(loc); o.rotation_euler = dvec.to_track_quat('-Z', 'Y').to_euler()
    return o
tgt = (head_x, 0, ztop - 0.18)
KEY, FILL, RIM = args.light
area('key', (head_x - 1.1, -1.3, ztop + 0.7), KEY, 1.6, (1.0, 0.97, 0.92), tgt)
area('fill', (head_x + 1.4, -1.2, ztop - 0.1), FILL, 2.0, (1.0, 0.98, 0.95), tgt)
area('rim', (head_x + 0.6, 1.3, ztop + 0.5), RIM, 1.0, (0.92, 0.97, 1.0), tgt)
world = bpy.data.worlds.new('w'); sc.world = world; world.use_nodes = True
bg = next(n for n in world.node_tree.nodes if n.type == 'BACKGROUND')
bg.inputs[0].default_value = (0.82, 0.80, 0.77, 1); bg.inputs[1].default_value = args.world

# ---- render settings ----
sc.render.engine = 'CYCLES'
cy = sc.cycles; cy.samples = args.samples; cy.use_denoising = True
try:
    cy.device = 'GPU'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'; prefs.get_devices()
    for d in prefs.devices: d.use = True
except Exception as e: print('gpu fallback', e)
cy.seed = 7; cy.use_animated_seed = False
sc.render.film_transparent = True
sc.render.image_settings.file_format = 'PNG'; sc.render.image_settings.color_mode = 'RGBA'
sc.render.image_settings.color_depth = '8'
sc.view_settings.view_transform = 'Standard'; sc.view_settings.look = 'None'
sc.render.fps = 30
sc.render.resolution_x = sc.render.resolution_y = args.size; sc.render.resolution_percentage = 100

# ---- idle pose through the skeleton ----
def rot_arm_space(name, axis, deg):
    """Rotation about an armature-space axis expressed as the bone's local quaternion."""
    if name not in pb: return Quaternion()
    b = arm.data.bones[name]
    m = b.matrix_local.to_3x3()
    q = Quaternion(Vector(axis), math.radians(deg))
    return (m.inverted() @ q.to_matrix() @ m).to_quaternion()

def pose(t):
    # t in [0,1). One breath (inhale peak at 0.45), neck sway one cycle, out of phase.
    br = 0.5 - 0.5 * math.cos(2 * math.pi * t)
    sway = math.sin(2 * math.pi * (t + 0.15))
    nod = math.sin(2 * math.pi * (t + 0.40))
    X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)
    keys = {
        'Spine02': [(X, -0.35 * br)],
        'Spine01': [(X, -0.45 * br)],
        'Spine':   [(X, -0.55 * br)],
        'LeftShoulder':  [(Y, 0.9 * br)],
        'RightShoulder': [(Y, -0.9 * br)],
        'neck': [(Y, roll / 2), (X, pitch / 2), (Z, yaw / 2), (X, 0.9 * br), (Z, 0.8 * sway), (Y, 0.35 * sway)],
        'Head': [(Y, roll / 2), (X, pitch / 2), (Z, yaw / 2), (X, 0.45 * nod), (Z, 0.6 * sway), (Y, 0.5 * sway)],
    }
    for n, rots in keys.items():
        if n not in pb: continue
        q = Quaternion()
        for ax, d in rots: q = rot_arm_space(n, ax, d) @ q
        pb[n].rotation_quaternion = q
    bpy.context.view_layer.update()

import os; os.makedirs(args.out, exist_ok=True)
# head-top check in screen space at frame 0
pose(0.0)
from bpy_extras.object_utils import world_to_camera_view
pts0 = list(world_verts(meshes))
top_ndc = max(world_to_camera_view(sc, cam, p).y for p in pts0)
# shift camera so the visible head top sits at 8% from the top edge (exact, in image space)
cam.location.z += (top_ndc - 0.92) * H
bpy.context.view_layer.update()
top_ndc2 = max(world_to_camera_view(sc, cam, p).y for p in pts0)
info = {'id': args.id, 'rigged_source': rigged, 'bones': [p.name for p in pb], 'head_top_from_top': round(1 - top_ndc2, 4),
        'shape_keys': sum(1 for o in meshes if o.data.shape_keys)}
print('INFO', json.dumps(info))
json.dump(info, open(os.path.join(args.out, 'render-info.json'), 'w'))

frames = [] if args.hero_only else range(args.frames) if args.only_frame < 0 else [args.only_frame]
sc.render.resolution_x = sc.render.resolution_y = args.size; sc.render.resolution_percentage = 100
for f in frames:
    pose(f / args.frames)
    sc.render.filepath = os.path.join(args.out, f'idle-{f:03d}.png')
    bpy.ops.render.render(write_still=True)
if args.hero and args.only_frame < 0:
    pose(0.0)
    # wider chest-up framing for the widget/contact still; head top stays at 8%
    Hh = args.hero_frame_h; cam_d.ortho_scale = Hh
    top_z = cam.location.z + H / 2 - 0.08 * H
    cam.location.z = top_z + 0.08 * Hh - Hh / 2
    sc.render.resolution_x = sc.render.resolution_y = args.hero
    cy.samples = args.samples * 2
    sc.render.filepath = os.path.join(args.out, 'hero.png')
    bpy.ops.render.render(write_still=True)
