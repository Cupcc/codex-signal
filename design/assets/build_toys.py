"""Build Codex Signal's original characters: the blue bracket companion (Codex)
and the orange crab (Claude Code). Python 3; no dependencies."""
from pathlib import Path
import json
import math

ROOT = Path(__file__).resolve().parent
STATES = {
    'idle': '团团正在休息', 'working': '团团正在工作',
    'attention': '团团举手等待确认', 'question': '团团有个问题',
    'error': '团团提醒运行中断',
    'ready': '团团托着结果等待查看',
}
DEFS = '''<defs>
<linearGradient id="shell" x1=".18" y1="0" x2=".74" y2="1" gradientUnits="objectBoundingBox"><stop stop-color="#91C7FF"/><stop offset=".38" stop-color="#4B9AFF"/><stop offset=".78" stop-color="#327AE9"/><stop offset="1" stop-color="#245AC1"/></linearGradient>
<linearGradient id="fin" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#9FD4FF"/><stop offset=".5" stop-color="#63AEFF"/><stop offset="1" stop-color="#3276DD"/></linearGradient>
<linearGradient id="face" x1="0" y1="0" x2=".2" y2="1"><stop stop-color="#F3FAFF"/><stop offset="1" stop-color="#C3E2FF"/></linearGradient>
<radialGradient id="ground"><stop stop-color="#10254F" stop-opacity=".25"/><stop offset="1" stop-color="#10254F" stop-opacity="0"/></radialGradient>
</defs>'''

def badge(kind, mini=False):
    if kind not in ('attention','question','error','ready'):
        return ''
    color = {'attention':'#FFC57B','question':'#C5B8FF','error':'#FFADA6','ready':'#D8EDFF'}[kind]
    symbol = {
        'attention':'<path d="M108 11v8m0 5v.2"/>',
        'question':'<path d="M104 13c0-5 9-5 9 0 0 4-5 3-5 7m0 4v.2"/>',
        'error':'<path d="m104 13 8 8m0-8-8 8"/>',
        'ready':'<rect x="103" y="10" width="10" height="14" rx="2"/><path d="M106 15h4m-4 4h4"/>',
    }[kind]
    mark = '<g aria-hidden="true"><circle cx="108" cy="17" r="13" fill="'+color+'" stroke="#15345F" stroke-opacity=".16"/><g fill="none" stroke="#15345F" stroke-width="3" stroke-linecap="round">'+symbol+'</g></g>'
    return '<g transform="translate(-30.5 -.85) scale(1.25)">'+mark+'</g>' if mini else mark

def eyes(kind):
    if kind == 'idle':
        return '<path d="M44 61q5 6 10 0m17 0q5 6 10 0" fill="none" stroke="#15345F" stroke-width="3.8" stroke-linecap="round"/>'
    if kind == 'error':
        return '<path d="m44 57 10 3m17 0 10-3" fill="none" stroke="#15345F" stroke-width="3.8" stroke-linecap="round"/><ellipse cx="62.5" cy="73" rx="3" ry="2.5" fill="#15345F"/>'
    if kind == 'working':
        return '<rect x="45" y="59" width="8" height="11" rx="4" fill="#15345F"/><rect x="72" y="59" width="8" height="11" rx="4" fill="#15345F"/>'
    return '<rect x="44" y="54" width="9" height="14" rx="4.5" fill="#15345F"/><rect x="73" y="54" width="9" height="14" rx="4.5" fill="#15345F"/><path d="M59 74q4 3 8 0" fill="none" stroke="#52779B" stroke-width="2" stroke-linecap="round"/>'

def build(kind, mini=False):
    shell = '''<path d="M39 25C52 19 77 19 91 28C105 37 109 56 105 75C101 95 86 104 64 104C40 104 25 94 23 75C20 54 24 34 39 25Z" fill="url(#shell)"/>
<path class="detail" d="M37 33C49 25 70 25 82 29" fill="none" stroke="#D8EEFF" stroke-opacity=".75" stroke-width="2.4" stroke-linecap="round"/>
<path d="M38 45C49 39 78 39 88 46C97 53 96 72 86 79C76 85 48 84 38 78C29 71 29 52 38 45Z" fill="#2464CC" opacity=".5" transform="translate(0 2)"/>
<path d="M38 44C49 38 78 38 88 45C97 52 96 71 86 78C76 84 48 83 38 77C29 70 29 51 38 44Z" fill="url(#face)"/>
<path class="detail" d="M46 94C56 98 75 98 84 93" fill="none" stroke="#A7D7FF" stroke-opacity=".3" stroke-width="1.6" stroke-linecap="round"/>'''
    left = '<path d="M25 58C13 59 10 73 16 84C19 89 24 91 27 87C29 83 24 80 23 75C21 70 29 63 25 58Z" fill="url(#fin)"/>'
    right = '<path d="M103 58C115 59 118 73 112 84C109 89 104 91 101 87C99 83 104 80 105 75C107 70 99 63 103 58Z" fill="url(#fin)"/>'
    if kind in ('attention','question'):
        right = '<path d="M103 68C112 65 118 56 116 45C115 39 110 37 107 42C105 46 108 50 104 54C100 58 97 63 103 68Z" fill="url(#fin)"/>'
    if kind == 'error':
        left = '<path d="M26 60C17 51 7 54 9 62C10 67 18 68 23 72Z" fill="url(#fin)"/>'
        right = '<path d="M102 60C111 51 121 54 119 62C118 67 110 68 105 72Z" fill="url(#fin)"/>'
    if kind == 'working':
        # Lower and compress the face as the head bows toward the task.
        shell = shell.replace('<path d="M38 45', '<g transform="translate(0 18) scale(1 .83)"><path d="M38 45')
        shell = shell.replace('<path class="detail" d="M46', '</g><path class="detail" d="M46')
        body = shell + '<g class="m-eyes"><g transform="translate(0 18) scale(1 .83)">'+eyes(kind)+'</g></g>'
    else:
        body = shell + '<g class="m-eyes">' + eyes(kind) + '</g>'
    if kind == 'question':
        body = '<g transform="rotate(-8 64 66)">'+body+'</g>'
    if kind == 'ready':
        body += '<rect x="44" y="86" width="40" height="24" rx="5" fill="#E3F1FF" stroke="#668BAD" stroke-width="2"/><path d="M53 94h22m-22 7h15" stroke="#668BAD" stroke-width="3" stroke-linecap="round"/>'
        left = '<path d="M24 68C20 80 29 98 43 99C49 99 50 92 44 90C35 87 35 77 31 70Z" fill="url(#fin)"/>'
        right = '<path d="M104 68C108 80 99 98 85 99C79 99 78 92 84 90C93 87 93 77 97 70Z" fill="url(#fin)"/>'
    if kind == 'working':
        left = '<path d="M24 70C24 82 34 91 45 88C51 86 50 80 44 79C36 78 33 71 29 68Z" fill="url(#fin)"/>'
        right = '<path d="M104 70C104 82 94 91 83 88C77 86 78 80 84 79C92 78 95 71 99 68Z" fill="url(#fin)"/>'
        body += '<g class="detail" fill="none" stroke="#D8EDFF" stroke-width="2.7" stroke-linecap="round" stroke-linejoin="round"><path d="m54 87 4 3-4 3m10 0h7"/></g>'
    if mini:
        # Optical variant: larger body/face, no highlights, no ground shadow.
        body = '<g transform="translate(-7 -7) scale(1.11)">'+body+'</g>'
    art = ('<g class="m-character"><g class="m-body">'+body+'</g>'
           +'<g class="m-left">'+left+'</g><g class="m-right">'+right+'</g></g>'
           +'<g class="m-badge">'+badge(kind, mini)+'</g>')
    ground = '' if mini else '<ellipse class="detail" cx="64" cy="111" rx="42" ry="7" fill="url(#ground)"/>'
    style = '<style>.detail{display:none}</style>' if mini else ''
    return '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128" role="img" aria-label="'+STATES[kind]+'"><title>'+STATES[kind]+'</title><!-- Original blue bracket companion for Codex Signal. -->'+DEFS+style+ground+art+'</svg>\n'

# Idle's open eyes, blinked in by the native and web animation.
OPEN_EYES = {
    'toy': '<rect x="45" y="57" width="8" height="10" rx="4" fill="#15345F"/><rect x="72" y="57" width="8" height="10" rx="4" fill="#15345F"/>',
}


# ---------------------------------------------------------------------------
# Claude Code: original orange crab 「钳钳」. Same layer classes, poses and badge
# slot as the companion, so both share one animation track set. No blue paint.
CRAB_STATES = {
    'idle': '钳钳正在休息', 'working': '钳钳正在工作',
    'attention': '钳钳举钳等待确认', 'question': '钳钳有个问题',
    'error': '钳钳提醒运行中断',
    'ready': '钳钳捧着结果等待查看',
}
CRAB_INK = '#3D1C0C'
CRAB_DEFS = '''<defs>
<linearGradient id="crabShell" x1=".2" y1="0" x2=".7" y2="1" gradientUnits="objectBoundingBox"><stop stop-color="#FFB98A"/><stop offset=".38" stop-color="#FF8F4A"/><stop offset=".78" stop-color="#F26B26"/><stop offset="1" stop-color="#D9531A"/></linearGradient>
<linearGradient id="crabClaw" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#FFC79C"/><stop offset=".5" stop-color="#FF9550"/><stop offset="1" stop-color="#E2621F"/></linearGradient>
<linearGradient id="crabFace" x1="0" y1="0" x2=".2" y2="1"><stop stop-color="#FFF7EE"/><stop offset="1" stop-color="#FFDDC2"/></linearGradient>
<radialGradient id="crabGround"><stop stop-color="#5C2A0E" stop-opacity=".25"/><stop offset="1" stop-color="#5C2A0E" stop-opacity="0"/></radialGradient>
</defs>'''
# Pupils sit in the eye bulbs at (48.5, 27) and (79.5, 27); working looks down.
CRAB_EYE_Y = {'default': 27, 'working': 30.5}
OPEN_EYES['crab'] = ('<rect x="45" y="22" width="7" height="10" rx="3.5" fill="'+CRAB_INK+'"/>'
                     '<rect x="76" y="22" width="7" height="10" rx="3.5" fill="'+CRAB_INK+'"/>')


def crab_badge(kind, mini=False):
    if kind not in ('attention','question','error','ready'):
        return ''
    color = {'attention':'#FFC57B','question':'#C5B8FF','error':'#FFADA6','ready':'#FFE7D1'}[kind]
    return badge(kind, mini).replace('#15345F', CRAB_INK).replace('#D8EDFF', color)


def crab_eyes(kind):
    ink = CRAB_INK
    if kind == 'idle':
        return '<path d="M43 28q5.5 5 11 0m20 0q5.5 5 11 0" fill="none" stroke="'+ink+'" stroke-width="3.6" stroke-linecap="round"/>'
    if kind == 'error':
        return ('<rect x="46" y="25.5" width="5" height="7" rx="2.5" fill="'+ink+'"/><rect x="77" y="25.5" width="5" height="7" rx="2.5" fill="'+ink+'"/>'
                '<path d="m42 19 12 4m32-4-12 4" fill="none" stroke="'+ink+'" stroke-width="3.2" stroke-linecap="round"/>')
    if kind == 'working':
        return '<rect x="45.5" y="26" width="6" height="9" rx="3" fill="'+ink+'"/><rect x="76.5" y="26" width="6" height="9" rx="3" fill="'+ink+'"/>'
    return '<rect x="45" y="21.5" width="7" height="11" rx="3.5" fill="'+ink+'"/><rect x="76" y="21.5" width="7" height="11" rx="3.5" fill="'+ink+'"/>'


def pincer(joint, center, r, opening):
    """An arm from the shell to a round claw with a V notch facing `opening` degrees."""
    def point(angle, radius):
        a = math.radians(angle)
        return f'{center[0] + radius * math.cos(a):.1f} {center[1] + radius * math.sin(a):.1f}'
    arm = (f'<path d="M{joint[0]} {joint[1]}L{center[0]} {center[1]}" stroke="#EE7430" '
           'stroke-width="7" stroke-linecap="round"/>')
    claw = (f'<path d="M{point(opening, r * .2)}L{point(opening + 27, r)}'
            f'A{r} {r} 0 1 1 {point(opening - 27, r)}Z" fill="url(#crabClaw)"/>')
    shine = f'<circle class="detail" cx="{center[0] - r * .3:.1f}" cy="{center[1] + r * .25:.1f}" r="{r * .22:.1f}" fill="#FFE6D2" opacity=".7"/>'
    return arm + claw + shine


def mirror(joint, center, r, opening):
    return (128 - joint[0], joint[1]), (128 - center[0], center[1]), r, 180 - opening


CRAB_CLAWS = {
    'rest': ((30, 78), (15, 63), 11, -90),
    # Claws are described on the left; mirror() places the right one.
    'raised': ((28, 66), (14, 44), 11, -90),
    'pondering': ((28, 66), (16, 44), 11, -55),
    'working': ((34, 82), (42, 89), 10, -55),
    'ready': ((30, 84), (42, 96), 9, 0),
    'error': ((28, 82), (14, 88), 10, 125),
    'idle': ((30, 84), (19, 90), 10, -60),
}


def build_crab(kind, mini=False):
    legs = ''.join(f'<path d="M{x0} {y0}L{x1} {y1}M{128 - x0} {y0}L{128 - x1} {y1}"/>'
                   for x0, y0, x1, y1 in ((38, 89, 30, 101), (46, 93, 41, 105), (55, 95, 53, 106)))
    shell = ('<g fill="none" stroke="#D9581C" stroke-width="5.5" stroke-linecap="round">'+legs+'</g>'
             '<rect x="44" y="27" width="9" height="20" rx="4.5" fill="#F07A35"/><rect x="75" y="27" width="9" height="20" rx="4.5" fill="#F07A35"/>'
             '<path d="M64 42C84 42 100 49 104 64C108 80 98 95 78 98C70 99 58 99 50 98C30 95 20 80 24 64C28 49 44 42 64 42Z" fill="url(#crabShell)"/>'
             '<path d="M33 84C46 94 82 94 95 84C90 94 78 98 64 98C50 98 38 94 33 84Z" fill="#C94A14" opacity=".35"/>'
             '<path class="detail" d="M36 58C42 50 54 46 66 46" fill="none" stroke="#FFE6D2" stroke-opacity=".8" stroke-width="2.4" stroke-linecap="round"/>'
             '<path d="M44 70C50 63 78 63 84 70C89 77 84 88 74 90C68 91 60 91 54 90C44 88 39 77 44 70Z" fill="url(#crabFace)"/>'
             '<circle cx="48.5" cy="27" r="10" fill="url(#crabFace)" stroke="#E06A2A" stroke-width="2.5"/>'
             '<circle cx="79.5" cy="27" r="10" fill="url(#crabFace)" stroke="#E06A2A" stroke-width="2.5"/>')
    mouth = {
        'error': '<ellipse cx="64" cy="77" rx="3" ry="2.5" fill="'+CRAB_INK+'"/>',
        'idle': '<path d="M61 76q3 2 6 0" fill="none" stroke="#A4502A" stroke-width="2" stroke-linecap="round"/>',
        'working': '<g class="detail" fill="none" stroke="#D2622A" stroke-width="2.7" stroke-linecap="round" stroke-linejoin="round"><path d="m55 74 4 3-4 3m10 0h7"/></g>',
    }.get(kind, '<path d="M59 76q5 4 10 0" fill="none" stroke="#A4502A" stroke-width="2.2" stroke-linecap="round"/>')
    body = shell + mouth + '<g class="m-eyes">' + crab_eyes(kind) + '</g>'
    if kind == 'question':
        body = '<g transform="rotate(-8 64 66)">'+body+'</g>'
    if kind == 'ready':
        body += ('<rect x="44" y="84" width="40" height="24" rx="5" fill="#FFF3E6" stroke="#B8693C" stroke-width="2"/>'
                 '<path d="M53 92h22m-22 7h15" stroke="#B8693C" stroke-width="3" stroke-linecap="round"/>')
    pose = {'attention': 'rest', 'question': 'rest'}.get(kind, kind)
    left = CRAB_CLAWS[pose]
    right = CRAB_CLAWS[{'attention': 'raised', 'question': 'pondering'}.get(kind, pose)]
    if mini:
        body = '<g transform="translate(-7 -7) scale(1.11)">'+body+'</g>'
    art = ('<g class="m-character"><g class="m-body">'+body+'</g>'
           +'<g class="m-left">'+pincer(*left)+'</g><g class="m-right">'+pincer(*mirror(*right))+'</g></g>'
           +'<g class="m-badge">'+crab_badge(kind, mini)+'</g>')
    ground = '' if mini else '<ellipse class="detail" cx="64" cy="111" rx="44" ry="7" fill="url(#crabGround)"/>'
    style = '<style>.detail{display:none}</style>' if mini else ''
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128" role="img" aria-label="'
            +CRAB_STATES[kind]+'"><title>'+CRAB_STATES[kind]+'</title><!-- Original orange crab for Claude Code sessions in Codex Signal. -->'
            +CRAB_DEFS+style+ground+art+'</svg>\n')


# Skin name → (file prefix, builder). The file prefix is also the art key prefix.
SKINS = {'toy': ('toy-', build), 'crab': ('crab-', build_crab)}


if __name__ == '__main__':
    frames = {}
    for skin, (prefix, builder) in SKINS.items():
        key = '' if skin == 'toy' else prefix
        for state in STATES:
            (ROOT / (prefix+state+'.svg')).write_text(builder(state), encoding='utf-8')
            (ROOT / (prefix+'mini-'+state+'.svg')).write_text(builder(state, True), encoding='utf-8')
            for mini in (False, True):
                frames[key+('mini-' if mini else '')+state] = builder(state, mini)
    (ROOT / 'mascot-art.js').write_text(
        '// Generated by build_toys.py; edit the generator instead.\n'
        + 'window.CodexMascotArt = '+json.dumps(frames, ensure_ascii=False)+';\n'
        + 'window.CodexMascotOpenEyes = '+json.dumps(OPEN_EYES, ensure_ascii=False)+';\n', encoding='utf-8')
    print(f'Generated {len(SKINS) * len(STATES) * 2} SVGs and the offline animation artwork bundle.')
