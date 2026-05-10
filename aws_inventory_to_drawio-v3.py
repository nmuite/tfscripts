#!/usr/bin/env python3
"""
aws_inventory_to_drawio.py  (v3 — official AWS4 shapes + containment)
======================================================================
Reads the CSV produced by aws_inventory-v1_5_8.sh and generates a draw.io
diagram using the official AWS Architecture Icons (mxgraph.aws4 library).

CONTAINMENT HIERARCHY
─────────────────────
  Region group  (mxgraph.aws4.group / group_aws_cloud_alt)
    └─ VPC group  (grIcon=group_vpc)
         ├─ Public Subnet group  (grIcon=group_public_subnet)
         │    ├─ EC2 Instance icon
         │    ├─ NAT Gateway icon  (linked to its EIP)
         │    └─ Lambda icon (if subnet-bound)
         ├─ Private Subnet group  (grIcon=group_private_subnet)
         │    ├─ EC2 Instance icon
         │    ├─ RDS / Aurora icon
         │    └─ ElastiCache icon
         ├─ Internet Gateway icon   (VPC-level)
         ├─ Virtual Private Gateway icon
         ├─ Security Group icon
         ├─ Route Table icon
         ├─ Load Balancer icon
         ├─ ECS / EKS icon
         └─ Lambda icon (VPC, no specific subnet)
    └─ Transit Gateway icon        (region-level)
    └─ TGW Attachment / RTB icons
    └─ Customer Gateway / VPN icons
    └─ DX icons
    └─ Free-floating regional services
  Global group
    └─ S3, IAM, CloudFront, DX Gateways/Connections

SHAPE STRATEGY
──────────────
  Containers  →  shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.<grIcon>
  Resources   →  shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.<name>
                 + official AWS category fillColor + gradientColor
  Special dedicated shapes (no resourceIcon wrapper):
    nat_gateway, internet_gateway, customer_gateway, vpn_gateway,
    transit_gateway, elastic_ip_address, route_table, vpc_router

REQUIREMENTS:  Python 3.8+, stdlib only.

USAGE
─────
  python3 aws_inventory_to_drawio.py <inventory.csv> [output.drawio]
"""

import csv, sys, os, math, xml.etree.ElementTree as ET
from collections import defaultdict, Counter

# ══════════════════════════════════════════════════════════════════════════════
#  AWS OFFICIAL ICON DEFINITIONS
#  Each entry: (resIcon_or_shape, fillColor, gradientColor, fontColor)
#  gradientColor=None means no gradient (use fillColor solid)
#  shape=None means use shape=mxgraph.aws4.resourceIcon with resIcon
# ══════════════════════════════════════════════════════════════════════════════

# AWS category colours (official)
_C = {
    "compute":     ("#D05C17", "#F78E04"),   # orange
    "storage":     ("#277116", "#60A337"),   # green
    "database":    ("#C925D1", "#E57CD8"),   # purple
    "network":     ("#5A30B5", "#945DF2"),   # violet
    "security":    ("#DD344C", "#F34482"),   # red-pink
    "mgmt":        ("#E7157B", "#F34482"),   # pink
    "messaging":   ("#E7157B", "#F34482"),   # pink
    "ml":          ("#01A88D", "#67C7B7"),   # teal
    "devtools":    ("#C7131F", "#F54749"),   # red
}

# (resIcon name OR dedicated shape name, fill, gradient, is_dedicated_shape)
# is_dedicated_shape=True → use shape=mxgraph.aws4.<name> directly (no resourceIcon wrapper)
ICON_DEF = {
    # ── Compute ────────────────────────────────────────────────────────────
    "EC2 Instance":           ("ec2",                       *_C["compute"],  False),
    "ECS Cluster":            ("ecs",                       *_C["compute"],  False),
    "EKS Cluster":            ("eks",                       *_C["compute"],  False),
    "Lambda Function":        ("lambda",                    *_C["compute"],  False),
    "Load Balancer":          ("elastic_load_balancing",    *_C["network"],  False),
    # ── Storage ────────────────────────────────────────────────────────────
    "S3 Bucket":              ("s3",                        *_C["storage"],  False),
    "EBS Volume":             ("elastic_block_store",       *_C["storage"],  False),
    # ── Database ───────────────────────────────────────────────────────────
    "RDS Instance":           ("rds",                       *_C["database"], False),
    "RDS Cluster":            ("aurora",                    *_C["database"], False),
    "ElastiCache":            ("elasticache",               *_C["database"], False),
    "DynamoDB Table":         ("dynamodb",                  *_C["database"], False),
    # ── Networking ─────────────────────────────────────────────────────────
    "Internet Gateway":       ("internet_gateway",          *_C["network"],  True),
    "NAT Gateway":            ("nat_gateway",               *_C["network"],  True),
    "Elastic IP":             ("elastic_ip_address",        *_C["network"],  True),
    "Route Table":            ("route_table",               *_C["network"],  True),
    "Security Group":         ("security_group",            *_C["network"],  True),
    "Virtual Private Gateway":("vpn_gateway",               *_C["network"],  True),
    "Customer Gateway":       ("customer_gateway",          *_C["network"],  True),
    "VPN Connection":         ("site_to_site_vpn",          *_C["network"],  True),
    "Transit Gateway":        ("transit_gateway",           *_C["network"],  True),
    "TGW Attachment":         ("transit_gateway",           *_C["network"],  True),
    "TGW Route Table":        ("route_table",               *_C["network"],  True),
    # ── Direct Connect ─────────────────────────────────────────────────────
    "DX Connection":          ("direct_connect",            *_C["network"],  False),
    "DX Gateway":             ("direct_connect",            *_C["network"],  False),
    "DX Virtual Interface":   ("direct_connect",            *_C["network"],  False),
    # ── Messaging ──────────────────────────────────────────────────────────
    "SNS Topic":              ("sns",                       *_C["messaging"],False),
    "SQS Queue":              ("sqs",                       *_C["messaging"],False),
    # ── Security ───────────────────────────────────────────────────────────
    "IAM User":               ("identity_and_access_management", *_C["security"], False),
    "Secret":                 ("secrets_manager",           *_C["security"], False),
    "SSM Parameter":          ("systems_manager_parameter_store", *_C["security"], False),
    # ── CDN ────────────────────────────────────────────────────────────────
    "CloudFront":             ("cloudfront",                *_C["network"],  False),
}

# Fallback for unknown types
_DEFAULT_ICON = ("general",  "#232F3E", None, False)

# ── AWS4 group container styles ────────────────────────────────────────────────
# grIcon, strokeColor, fillColor, fontColor, labelColor
GROUP_STYLES = {
    "region":          ("group_aws_cloud_alt", "#232F3E", "none",    "#232F3E"),
    "vpc":             ("group_vpc",           "#8C4FFF", "none",    "#8C4FFF"),
    "subnet_public":   ("group_public_subnet", "#248814", "#E9F3E6", "#248814"),
    "subnet_private":  ("group_private_subnet","#147EBA", "#E6F2F8", "#147EBA"),
}

# Connector points used on all AWS4 group/resource shapes
_POINTS = ("points=[[0,0,0],[0.25,0,0],[0.5,0,0],[0.75,0,0],[1,0,0],"
           "[0,1,0],[0.25,1,0],[0.5,1,0],[0.75,1,0],[1,1,0],"
           "[0,0.25,0],[0,0.5,0],[0,0.75,0],[1,0.25,0],[1,0.5,0],[1,0.75,0]]")

# ══════════════════════════════════════════════════════════════════════════════
#  LAYOUT CONSTANTS
# ══════════════════════════════════════════════════════════════════════════════
ICW, ICH = 52, 52       # icon width / height
ICX, ICY = 60, 70       # icon cell total (icon + label below)
NGX, NGY = 24, 50       # gap between icon cells (x, y) — label sits below icon
SNX, SNY = 30, 50       # subnet inner pad x / top (below header)
SNG      = 20           # gap between sibling subnets
VPX, VPY = 30, 50       # vpc inner pad x / top (below group header)
VPG      = 30           # vertical gap between subnet row and vpc-level icons
RPX, RPY = 40, 60       # region pad x / top
RGY      = 50           # gap between regions on canvas
COLS_SN  = 4            # max icons per row in a subnet
COLS_VPC = 6            # max icons per row in vpc-level section
COLS_RL  = 7            # max icons per row in region-level section
GRP_HDR  = 40           # group container header/title height
GRP_PAD  = 20           # bottom/side padding inside a group container

EDGE_STYLE = (
    "edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;"
    "jettySize=auto;html=1;fontSize=9;fontColor=#444444;"
    "strokeColor=#5A30B5;strokeWidth=1.5;"
)
EDGE_DASHED = EDGE_STYLE + "dashed=1;dashPattern=8 4;"

# ══════════════════════════════════════════════════════════════════════════════
#  SMALL UTILITIES
# ══════════════════════════════════════════════════════════════════════════════
_uid = 1
def uid():
    global _uid; _uid += 1; return str(_uid)

def trunc(s, n=22):
    s = s or ""; return s if len(s) <= n else s[:n-1]+"…"

def parse_attrs(s):
    out = {}
    for p in (s or "").split(","):
        if "=" in p:
            k, v = p.split("=", 1); out[k.strip()] = v.strip()
    return out

SKIP = {"","none","N/A","detached","unassociated","false","true","0","null"}
def split_ids(v):
    return [t.strip() for t in (v or "").split(",") if t.strip() not in SKIP]

def tooltip_str(r):
    return (f"Type:  {r.get('ResourceType','')}\n"
            f"ID:    {r.get('ResourceID','')}\n"
            f"Name:  {r.get('Name','')}\n"
            f"State: {r.get('State','')}\n"
            f"ARN:   {r.get('ARN','')}\n"
            f"Attrs: {r.get('AdditionalAttributes','')}")

# ══════════════════════════════════════════════════════════════════════════════
#  STYLE BUILDERS
# ══════════════════════════════════════════════════════════════════════════════

def group_style(kind):
    grIcon, stroke, fill, fontc = GROUP_STYLES[kind]
    return (
        f"{_POINTS};outlineConnect=0;gradientColor=none;html=1;"
        f"whiteSpace=wrap;fontSize=11;fontStyle=1;"
        f"shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.{grIcon};"
        f"strokeColor={stroke};fillColor={fill};"
        f"verticalAlign=top;align=left;spacingLeft=30;"
        f"fontColor={fontc};dashed=0;"
        f"container=1;pointerEvents=0;collapsible=0;recursiveResize=0;"
    )

def icon_style(rtype):
    """Return the draw.io style string for a resource icon cell."""
    icon_name, fill, grad, dedicated = ICON_DEF.get(rtype, _DEFAULT_ICON)
    grad_part = f"gradientColor={grad};gradientDirection=north;" if grad else "gradientColor=none;"
    if dedicated:
        # Dedicated AWS4 shape (not resourceIcon wrapper)
        return (
            f"sketch=0;{_POINTS};outlineConnect=0;fontColor=#232F3E;"
            f"fillColor={fill};{grad_part}"
            f"strokeColor=none;dashed=0;"
            f"verticalLabelPosition=bottom;verticalAlign=top;"
            f"align=center;html=1;fontSize=10;fontStyle=0;aspect=fixed;"
            f"shape=mxgraph.aws4.{icon_name};"
        )
    else:
        return (
            f"sketch=0;{_POINTS};outlineConnect=0;fontColor=#232F3E;"
            f"fillColor={fill};{grad_part}"
            f"strokeColor=#ffffff;dashed=0;"
            f"verticalLabelPosition=bottom;verticalAlign=top;"
            f"align=center;html=1;fontSize=10;fontStyle=0;aspect=fixed;"
            f"shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.{icon_name};"
        )

# ══════════════════════════════════════════════════════════════════════════════
#  XML HELPERS
# ══════════════════════════════════════════════════════════════════════════════
def mk_group(doc, cid, label, style, x, y, w, h, parent, tip=""):
    c = ET.SubElement(doc, "mxCell",
        id=cid, value=label, style=style, vertex="1", parent=parent)
    if tip: c.set("tooltip", tip)
    ET.SubElement(c, "mxGeometry",
        x=str(int(x)), y=str(int(y)), width=str(int(w)), height=str(int(h)),
        **{"as": "geometry"})
    return c

def mk_icon(doc, cid, label, style, x, y, parent, tip="", w=ICW, h=ICH):
    c = ET.SubElement(doc, "mxCell",
        id=cid, value=label, style=style, vertex="1", parent=parent)
    if tip: c.set("tooltip", tip)
    ET.SubElement(c, "mxGeometry",
        x=str(int(x)), y=str(int(y)), width=str(w), height=str(h),
        **{"as": "geometry"})
    return c

def mk_edge(doc, src, tgt, label="", dashed=False, parent="1"):
    if not src or not tgt or src == tgt: return
    style = EDGE_DASHED if dashed else EDGE_STYLE
    e = ET.SubElement(doc, "mxCell",
        id=uid(), value=label, style=style,
        edge="1", source=src, target=tgt, parent=parent)
    ET.SubElement(e, "mxGeometry", relative="1", **{"as": "geometry"})

# ══════════════════════════════════════════════════════════════════════════════
#  SIZING HELPERS
# ══════════════════════════════════════════════════════════════════════════════
def icon_grid_size(n, cols, pad_x=GRP_PAD, pad_y=GRP_PAD):
    """Outer (w, h) of a container holding n icons in a grid."""
    if n == 0: return 0, 0
    c = min(n, cols)
    r = math.ceil(n / c)
    w = pad_x*2 + c*ICX + max(c-1, 0)*NGX - (ICX - ICW)
    h = GRP_HDR + pad_y + r*ICY + max(r-1, 0)*NGY
    return w, h

def place_icons(doc, items, parent_cid, C, start_x, start_y, cols):
    """Emit icon cells for a list of resource rows inside a container."""
    if not items: return 0, 0
    c = min(len(items), cols)
    max_row = -1
    for idx, row in enumerate(items):
        rid = row["ResourceID"]
        if rid in C: continue
        ci = idx % c
        ri = idx // c
        max_row = max(max_row, ri)
        ix = start_x + ci * (ICX + NGX)
        iy = start_y + ri * (ICY + NGY)
        cid2 = uid()
        C[rid] = cid2
        name = trunc(row.get("Name","") or rid, 20)
        mk_icon(doc, cid2, name, icon_style(row["ResourceType"]),
                ix, iy, parent_cid, tip=tooltip_str(row))

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
def build_drawio(rows):

    # ── Indexes ────────────────────────────────────────────────────────────
    by_id   = {r["ResourceID"]: r for r in rows}
    by_name = {}
    for r in rows:
        nm = r.get("Name", "")
        if nm and nm not in by_name:
            by_name[nm] = r

    A = {r["ResourceID"]: parse_attrs(r.get("AdditionalAttributes",""))
         for r in rows}

    def resolve(v):
        if not v or v in SKIP: return None
        if v in by_id:   return v
        if v in by_name: return by_name[v]["ResourceID"]
        return None

    C = {}          # ResourceID → draw.io cell id
    placed = set()  # ResourceIDs already emitted

    edges = []      # (src_rid, dst_rid, label, dashed)
    edge_seen = set()

    def defer(src, dst, label="", dashed=False):
        if not src or not dst or src == dst: return
        k = (src, dst, label)
        if k not in edge_seen:
            edge_seen.add(k)
            edges.append((src, dst, label, dashed))

    # ── Group by region ────────────────────────────────────────────────────
    by_region = defaultdict(list)
    for r in rows:
        by_region[r.get("Region","global") or "global"].append(r)

    # ── XML root ───────────────────────────────────────────────────────────
    root = ET.Element("mxGraphModel",
        dx="1422", dy="762", grid="1", gridSize="10",
        guides="1", tooltips="1", connect="1", arrows="1",
        fold="1", page="1", pageScale="1",
        pageWidth="1654", pageHeight="1169",
        math="0", shadow="0")
    doc = ET.SubElement(root, "root")
    ET.SubElement(doc, "mxCell", id="0")
    ET.SubElement(doc, "mxCell", id="1", parent="0")

    canvas_x, canvas_y = 20, 20

    # ══════════════════════════════════════════════════════════════════════
    #  ITERATE REGIONS
    # ══════════════════════════════════════════════════════════════════════
    for region in sorted(by_region.keys()):
        rrows = by_region[region]

        def oftype(*types):
            return [r for r in rrows if r["ResourceType"] in types]

        vpcs      = oftype("VPC")
        subnets   = oftype("Subnet")
        igws      = oftype("Internet Gateway")
        natgws    = oftype("NAT Gateway")
        eips      = oftype("Elastic IP")
        sgs       = oftype("Security Group")
        rtbs      = oftype("Route Table")
        ec2s      = oftype("EC2 Instance")
        ebsvols   = oftype("EBS Volume")
        lbs       = oftype("Load Balancer")
        rdsi      = oftype("RDS Instance")
        rdsc      = oftype("RDS Cluster")
        lambdas   = oftype("Lambda Function")
        ecs_list  = oftype("ECS Cluster")
        eks_list  = oftype("EKS Cluster")
        ecache    = oftype("ElastiCache")
        dynamo    = oftype("DynamoDB Table")
        sns_l     = oftype("SNS Topic")
        sqs_l     = oftype("SQS Queue")
        secrets   = oftype("Secret")
        ssm_l     = oftype("SSM Parameter")
        s3_l      = oftype("S3 Bucket")
        iam_l     = oftype("IAM User")
        cf_l      = oftype("CloudFront")
        tgws      = oftype("Transit Gateway")
        tgw_atts  = oftype("TGW Attachment")
        tgw_rtbs  = oftype("TGW Route Table")
        cgws      = oftype("Customer Gateway")
        vgws      = oftype("Virtual Private Gateway")
        vpn_c     = oftype("VPN Connection")
        dx_conns  = oftype("DX Connection")
        dx_gws    = oftype("DX Gateway")
        dx_vifs   = oftype("DX Virtual Interface")

        # ── Quick attr helpers ─────────────────────────────────────────────
        def sn_vpc(sid):   return A[sid].get("VPC","")
        def sn_pub(sid):   return A[sid].get("PublicIP","false").lower()=="true"

        eip_by_alloc = {e["ResourceID"]: e for e in eips}
        eip_by_inst  = {}
        for e in eips:
            inst = A[e["ResourceID"]].get("Instance","")
            if inst: eip_by_inst[inst] = e
        alloc_to_nat = {}
        for n in natgws:
            alloc = A[n["ResourceID"]].get("AllocationId","")
            if alloc: alloc_to_nat[alloc] = n["ResourceID"]

        def eips_for_subnet(sid):
            out = []
            for ec in [r for r in ec2s if A[r["ResourceID"]].get("Subnet","")==sid]:
                if ec["ResourceID"] in eip_by_inst:
                    out.append(eip_by_inst[ec["ResourceID"]])
            for nat in [r for r in natgws if A[r["ResourceID"]].get("Subnet","")==sid]:
                alloc = A[nat["ResourceID"]].get("AllocationId","")
                if alloc and alloc in eip_by_alloc:
                    e = eip_by_alloc[alloc]
                    if e not in out: out.append(e)
            return out

        def vpc_attr(rid, key="VPC"): return A[rid].get(key,"")

        def subnet_children(sid):
            return (
                [r for r in ec2s    if A[r["ResourceID"]].get("Subnet","")==sid] +
                [r for r in natgws  if A[r["ResourceID"]].get("Subnet","")==sid] +
                [r for r in lambdas if A[r["ResourceID"]].get("Subnet","")==sid] +
                eips_for_subnet(sid)
            )

        def vpc_level_items(vid):
            return (
                [r for r in igws      if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in vgws      if A[r["ResourceID"]].get("VPC","") == vid] +
                [r for r in sgs       if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in rtbs      if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in lbs       if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in rdsi      if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in rdsc      if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in ecs_list  if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in eks_list  if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in ecache    if vpc_attr(r["ResourceID"])     == vid] +
                [r for r in lambdas
                 if vpc_attr(r["ResourceID"])==vid
                 and not A[r["ResourceID"]].get("Subnet","")]
            )

        # ── Measure VPC ────────────────────────────────────────────────────
        def measure_vpc(vid):
            v_sn = [s for s in subnets if sn_vpc(s["ResourceID"])==vid]
            sn_ws, sn_hs = [], []
            for sn in v_sn:
                ch = subnet_children(sn["ResourceID"])
                n = max(len(ch), 1)
                c = min(n, COLS_SN)
                r = math.ceil(n / c)
                sw = GRP_PAD*2 + c*(ICX+NGX) - NGX
                sh = GRP_HDR + GRP_PAD + r*(ICY+NGY) - NGY + GRP_PAD
                sn_ws.append(sw); sn_hs.append(sh)

            sub_row_w = sum(sn_ws) + SNG*(len(v_sn)-1) if v_sn else 0
            sub_row_h = max(sn_hs) if sn_hs else 0

            vl = vpc_level_items(vid)
            n2 = max(len(vl), 0)
            c2 = min(max(n2,1), COLS_VPC)
            r2 = math.ceil(max(n2,1)/c2)
            vl_w = GRP_PAD*2 + c2*(ICX+NGX) - NGX
            vl_h = (r2*(ICY+NGY) - NGY + GRP_PAD) if n2 else 0

            w = max(sub_row_w, vl_w) + VPX*2
            h = GRP_HDR + VPY + sub_row_h + (VPG + vl_h if n2 or v_sn else 0) + GRP_PAD
            return max(w, 400), max(h, 150)

        vpc_sizes = {v["ResourceID"]: measure_vpc(v["ResourceID"]) for v in vpcs}

        # ── Region-level items (outside VPCs) ──────────────────────────────
        # Anything not subnet/VPC scoped
        region_free = (
            tgws + tgw_atts + tgw_rtbs + cgws +
            [r for r in vgws if not A[r["ResourceID"]].get("VPC","")] +
            vpn_c + dx_conns + dx_gws + dx_vifs +
            dynamo + sns_l + sqs_l + secrets + ssm_l + ebsvols +
            [r for r in lambdas  if not A[r["ResourceID"]].get("VPC","")] +
            [r for r in ecs_list if not A[r["ResourceID"]].get("VPC","")] +
            [r for r in eks_list if not A[r["ResourceID"]].get("VPC","")] +
            [r for r in ecache   if not A[r["ResourceID"]].get("VPC","")] +
            (s3_l + iam_l + cf_l if region=="global" else [])
        )
        # Deduplicate
        seen_free = set()
        region_free_dedup = []
        for r in region_free:
            if r["ResourceID"] not in seen_free:
                seen_free.add(r["ResourceID"])
                region_free_dedup.append(r)
        region_free = region_free_dedup

        # ── Region container size ──────────────────────────────────────────
        total_vpc_h = sum(h for _,h in vpc_sizes.values()) + max(0,len(vpcs)-1)*VPG
        max_vpc_w   = max((w for w,_ in vpc_sizes.values()), default=0)

        n_free = len(region_free)
        c_free = min(max(n_free,1), COLS_RL)
        r_free = math.ceil(max(n_free,1)/c_free)
        free_w = c_free*(ICX+NGX) - NGX + RPX*2
        free_h = r_free*(ICY+NGY) - NGY if n_free else 0

        region_w = max(max_vpc_w + RPX*2, free_w)
        region_h = RPY + total_vpc_h + (VPG + free_h if n_free else 0) + GRP_PAD*2

        # ── Emit region group ──────────────────────────────────────────────
        region_cid = uid()
        mk_group(doc, region_cid,
                 f"Region: {region}",
                 group_style("region"),
                 canvas_x, canvas_y, region_w, region_h, "1")

        cur_y = RPY  # y-cursor inside region

        # ══════════════════════════════════════════════════════════════════
        #  VPC GROUPS
        # ══════════════════════════════════════════════════════════════════
        for vpc_row in vpcs:
            vid  = vpc_row["ResourceID"]
            vw, vh = vpc_sizes[vid]
            vw = max(vw, region_w - RPX*2)

            vpc_cid = uid()
            C[vid] = vpc_cid
            placed.add(vid)

            va   = A[vid]
            cidr = va.get("CIDR","")
            vlbl = f"{trunc(vpc_row.get('Name','') or vid, 28)}  {cidr}"
            mk_group(doc, vpc_cid, vlbl,
                     group_style("vpc"),
                     RPX, cur_y, vw, vh, region_cid,
                     tip=tooltip_str(vpc_row))

            vy = VPY          # y inside VPC (below its header)
            sx = VPX          # x cursor for subnets

            # ── Subnets ───────────────────────────────────────────────────
            v_subnets = [s for s in subnets if sn_vpc(s["ResourceID"])==vid]
            sn_heights = []

            for sn in v_subnets:
                sid  = sn["ResourceID"]
                pub  = sn_pub(sid)
                sa   = A[sid]
                ch   = subnet_children(sid)
                n    = max(len(ch), 1)
                c_   = min(n, COLS_SN)
                r_   = math.ceil(n / c_)
                sw   = GRP_PAD*2 + c_*(ICX+NGX) - NGX
                sh   = GRP_HDR + GRP_PAD + r_*(ICY+NGY) - NGY + GRP_PAD
                sn_heights.append(sh)

                sn_cid = uid()
                C[sid] = sn_cid
                placed.add(sid)

                kind = "subnet_public" if pub else "subnet_private"
                snlbl = (f"{'Public' if pub else 'Private'} Subnet  "
                         f"{trunc(sn.get('Name','') or sid, 20)}\n"
                         f"{sa.get('CIDR','')}  {sa.get('AZ','')}")
                mk_group(doc, sn_cid, snlbl,
                         group_style(kind),
                         sx, vy, sw, sh, vpc_cid,
                         tip=tooltip_str(sn))

                place_icons(doc, ch, sn_cid, C,
                            start_x=GRP_PAD,
                            start_y=GRP_HDR + GRP_PAD,
                            cols=c_)
                for item in ch: placed.add(item["ResourceID"])

                sx += sw + SNG

            sub_row_h = max(sn_heights) if sn_heights else 0

            # ── VPC-level icons ───────────────────────────────────────────
            vl = [r for r in vpc_level_items(vid) if r["ResourceID"] not in placed]
            if vl:
                vl_y = vy + sub_row_h + (VPG if v_subnets else 0)
                c2   = min(len(vl), COLS_VPC)
                place_icons(doc, vl, vpc_cid, C,
                            start_x=VPX,
                            start_y=vl_y,
                            cols=c2)
                for item in vl: placed.add(item["ResourceID"])

            cur_y += vh + VPG

        # ══════════════════════════════════════════════════════════════════
        #  REGION-LEVEL (free-floating) ICONS
        # ══════════════════════════════════════════════════════════════════
        if region_free:
            place_icons(doc, region_free, region_cid, C,
                        start_x=RPX,
                        start_y=cur_y,
                        cols=c_free)
            for r in region_free: placed.add(r["ResourceID"])

        canvas_y += region_h + RGY

    # ══════════════════════════════════════════════════════════════════════
    #  RELATIONSHIP EDGES
    # ══════════════════════════════════════════════════════════════════════
    for r in rows:
        rid   = r["ResourceID"]
        rtype = r["ResourceType"]
        a     = A[rid]

        if rtype == "Internet Gateway":
            defer(rid, resolve(a.get("VPC","")), "attached to")

        elif rtype == "Virtual Private Gateway":
            defer(rid, resolve(a.get("VPC","")), "attached to VPC")

        elif rtype == "NAT Gateway":
            alloc = a.get("AllocationId","")
            if alloc: defer(rid, resolve(alloc), "EIP", dashed=True)

        elif rtype == "Elastic IP":
            inst = a.get("Instance","")
            if inst: defer(rid, resolve(inst), "→", dashed=True)
            if rid in alloc_to_nat:
                defer(rid, alloc_to_nat[rid], "→ NAT", dashed=True)

        elif rtype == "TGW Attachment":
            tgw_rid = a.get("TGW","")
            att_typ = a.get("Type","")
            res_rid = a.get("Resource","")
            defer(rid, resolve(tgw_rid), f"→ TGW")
            defer(rid, resolve(res_rid), f"attaches")
            # Direct resource ↔ TGW edge (the key one the user asked for)
            defer(resolve(res_rid), resolve(tgw_rid), att_typ)

        elif rtype == "TGW Route Table":
            defer(rid, resolve(a.get("TGW","")), "RTB")

        elif rtype == "VPN Connection":
            defer(rid, resolve(a.get("CGW","")), "→ CGW")
            vgw = a.get("VGW",""); tgw = a.get("TGW","")
            if resolve(vgw): defer(rid, resolve(vgw), "→ VGW")
            if resolve(tgw): defer(rid, resolve(tgw), "→ TGW")

        elif rtype == "DX Virtual Interface":
            defer(rid, resolve(a.get("Connection","")), "via DX")
            defer(rid, resolve(a.get("DXGateway","")), "→ DX GW")

        elif rtype == "DX Gateway":
            for att in [r2 for r2 in rows if r2["ResourceType"]=="TGW Attachment"]:
                aa = A[att["ResourceID"]]
                if aa.get("Type","")=="direct-connect-gateway" and aa.get("Resource","")==rid:
                    defer(rid, resolve(aa.get("TGW","")), "→ TGW")

        elif rtype == "EC2 Instance":
            for sg in split_ids(a.get("SecurityGroups","") or a.get("SG","")):
                defer(rid, resolve(sg), "SG", dashed=True)

        elif rtype == "Load Balancer":
            for sg in split_ids(a.get("SecurityGroups","") or a.get("SG","")):
                defer(rid, resolve(sg), "SG", dashed=True)
            for sn in split_ids(a.get("Subnets","")):
                defer(rid, resolve(sn), "spans", dashed=True)

        elif rtype in ("RDS Instance", "RDS Cluster"):
            for sg in split_ids(a.get("SecurityGroups","") or a.get("SG","")):
                defer(rid, resolve(sg), "SG", dashed=True)

        elif rtype == "Lambda Function":
            for sg in split_ids(a.get("SecurityGroups","") or a.get("SG","")):
                defer(rid, resolve(sg), "SG", dashed=True)

        elif rtype == "EKS Cluster":
            for sg in split_ids(a.get("SecurityGroups","") or a.get("SG","")):
                defer(rid, resolve(sg), "SG", dashed=True)

        elif rtype == "ElastiCache":
            for sg in split_ids(a.get("SecurityGroups","") or a.get("SG","")):
                defer(rid, resolve(sg), "SG", dashed=True)

        elif rtype == "SQS Queue":
            dlq = a.get("DLQ","") or a.get("DLQArn","")
            if dlq: defer(rid, resolve(dlq), "DLQ →")

        elif rtype == "CloudFront":
            for orig in split_ids(a.get("Origins","")):
                bucket = orig.split(".")[0]
                if resolve(bucket): defer(rid, resolve(bucket), "origin")

    # ── Flush edges ────────────────────────────────────────────────────────
    emitted = set()
    for src_rid, dst_rid, label, dashed in edges:
        sc = C.get(src_rid)
        dc = C.get(dst_rid)
        if not sc or not dc or sc==dc: continue
        k = (sc, dc, label)
        if k in emitted: continue
        emitted.add(k)
        mk_edge(doc, sc, dc, label, dashed)

    # ── Serialise ──────────────────────────────────────────────────────────
    ET.indent(root, space="  ")
    xml = ET.tostring(root, encoding="unicode", xml_declaration=False)
    return f'<?xml version="1.0" encoding="UTF-8"?>\n{xml}\n'


# ══════════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════
def main():
    if len(sys.argv) < 2:
        print("Usage: python3 aws_inventory_to_drawio.py <inventory.csv> [output.drawio]")
        sys.exit(1)

    csv_path = sys.argv[1]
    if not os.path.isfile(csv_path):
        print(f"ERROR: File not found: {csv_path}"); sys.exit(1)

    out_path = sys.argv[2] if len(sys.argv) >= 3 else csv_path.replace(".csv",".drawio")
    if not out_path.endswith(".drawio"): out_path += ".drawio"

    rows = []
    with open(csv_path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if row.get("ResourceType","").strip() in ("","ResourceType"): continue
            rows.append(row)

    if not rows:
        print("ERROR: No resources found in CSV."); sys.exit(1)

    print(f"  Loaded {len(rows)} resources from {csv_path}")
    for rtype, n in sorted(Counter(r["ResourceType"] for r in rows).items()):
        print(f"    {n:4d}  {rtype}")

    xml = build_drawio(rows)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(xml)

    kb = os.path.getsize(out_path) // 1024
    print(f"\n  Diagram written → {out_path}  ({kb} KB)")
    print()
    print("  Open: app.diagrams.net → Extras → Edit Diagram  OR")
    print("        draw.io Desktop  → File → Open from Device")
    print()
    print("  NOTE: The AWS shape library must be enabled in draw.io.")
    print("        Extras → Edit Diagram will load shapes automatically.")
    print("        Or: View → Shapes → Search 'AWS' and enable AWS19.")

if __name__ == "__main__":
    main()
