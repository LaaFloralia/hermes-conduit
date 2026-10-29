import bpy, sys
src, dst = sys.argv[sys.argv.index('--')+1:][:2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
for o in list(bpy.data.objects):
    if o.name.startswith('Icosphere'): bpy.data.objects.remove(o)
for o in bpy.data.objects:
    if o.animation_data: o.animation_data_clear()
props = bpy.ops.wm.usd_export.get_rna_type().properties.keys()
kw = dict(filepath=dst, export_animation=False, export_materials=True, export_textures_mode='NEW' if 'export_textures_mode' in props else None)
kw = {k: v for k, v in kw.items() if v is not None and k in props or k == 'filepath'}
for k in ('export_armatures', 'only_deform_bones'):
    if k in props: kw[k] = True if k == 'export_armatures' else False
print('KW', kw)
bpy.ops.wm.usd_export(**kw)
