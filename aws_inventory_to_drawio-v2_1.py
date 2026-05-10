#!/usr/bin/env python3
"""
aws_inventory_to_drawio.py  (v2 — hierarchical containment + full relationships)
=================================================================================
Reads the CSV produced by aws_inventory-v1_5_8.sh and generates a draw.io
(.drawio / .xml) diagram with:

  CONTAINMENT HIERARCHY
  ─────────────────────
  Region swimlane
    └─ VPC swimlane
         ├─ Subnet swimlane  (public = green, private = yellow)
         │    ├─ EC2 Instance
         │    ├─ NAT Gateway  (+ its EIP card, linked)
         │    └─ Lambda (VPC-attached, per-subnet)
         ├─ Internet Gateway     (VPC-level)
         ├─ Virtual Private Gateway (VPC-level)
         ├─ Security Groups      (VPC-level)
         ├─ Route Tables         (VPC-level)
         ├─ Load Balancers       (VPC-level, linked to subnets + SGs)
         ├─ RDS Instances/Clusters (VPC-level, linked to SGs)
         ├─ ECS / EKS Clusters   (VPC-level, linked to SGs)
         └─ Lambda (VPC-attached, no explicit subnet)
    └─ Transit Gateways          (region-level, outside VPCs)
    └─ TGW Attachments           (region-level)
    └─ TGW Route Tables          (region-level)
    └─ Customer Gateways         (region-level)
    └─ Virtual Private Gateways  (not attached to VPCs)
    └─ VPN Connections           (region-level)
    └─ DX Virtual Interfaces     (region-level)
    └─ DX Connections / Gateways (region-level)
    └─ ElastiCache, DynamoDB, SNS, SQS, Secrets, SSM, EBS (region-level)
    └─ Lambda (no VPC)
  Global region
    └─ S3, IAM, CloudFront, DX Connections, DX Gateways

  RELATIONSHIP EDGES
  ──────────────────
  • TGW Attachment → TGW  AND  → attached resource (VPC / VPN / DX GW)
  • TGW Route Table → TGW
  • VPN Connection → Customer Gateway  AND  → VGW or TGW
  • Virtual Private Gateway → VPC
  • Internet Gateway → VPC
  • DX Virtual Interface → DX Connection  AND  → DX Gateway
  • DX Gateway → TGW (via attachment records)
  • Elastic IP → EC2 Instance (if associated)
  • Elastic IP → NAT Gateway (via AllocationId)
  • Security Group ← EC2, RDS, Lambda, LB, EKS, ElastiCache (dashed)
  • Load Balancer → Subnet spans (dashed)
  • CloudFront → S3 origin (name heuristic)
  • SQS → DLQ target queue

REQUIREMENTS:  Python 3.8+, stdlib only.

USAGE
─────
  python3 aws_inventory_to_drawio.py <inventory.csv> [output.drawio]
"""

import csv, sys, os, math, xml.etree.ElementTree as ET
from collections import defaultdict, Counter

# ══════════════════════════════════════════════════════════════════════════════
#  STYLE PALETTE
# ══════════════════════════════════════════════════════════════════════════════

# (fillColor, strokeColor, fontColor)
PAL = {
    "region":    ("#f5f5f5", "#b0b0b0", "#333333"),
    "vpc":       ("#dae8fc", "#6c8ebf", "#003060"),
    "sub_pub":   ("#d5e8d4", "#82b366", "#1a3a1a"),
    "sub_priv":  ("#fff2cc", "#d6b656", "#3a3000"),
    "ec2":       ("#d5e8d4", "#82b366", "#000000"),
    "rds":       ("#ffe6cc", "#d6b656", "#000000"),
    "lambda":    ("#e1d5e7", "#9673a6", "#000000"),
    "alb":       ("#dae8fc", "#6c8ebf", "#000000"),
    "ecs":       ("#d5e8d4", "#82b366", "#000000"),
    "eks":       ("#d5e8d4", "#82b366", "#000000"),
    "ecache":    ("#ffe6cc", "#d6b656", "#000000"),
    "dynamo":    ("#ffe6cc", "#d6b656", "#000000"),
    "s3":        ("#fff2cc", "#d6b656", "#000000"),
    "sns":       ("#f8cecc", "#b85450", "#000000"),
    "sqs":       ("#f8cecc", "#b85450", "#000000"),
    "igw":       ("#dae8fc", "#6c8ebf", "#000000"),
    "natgw":     ("#dae8fc", "#6c8ebf", "#000000"),
    "eip":       ("#fff2cc", "#d6b656", "#000000"),
    "sg":        ("#f5f5f5", "#999999", "#000000"),
    "rtb":       ("#f5f5f5", "#999999", "#000000"),
    "tgw":       ("#dae8fc", "#6c8ebf", "#000000"),
    "tgw_att":   ("#dae8fc", "#6c8ebf", "#000000"),
    "tgw_rtb":   ("#f5f5f5", "#999999", "#000000"),
    "cgw":       ("#dae8fc", "#6c8ebf", "#000000"),
    "vgw":       ("#dae8fc", "#6c8ebf", "#000000"),
    "vpn":       ("#dae8fc", "#6c8ebf", "#000000"),
    "dx_conn":   ("#dae8fc", "#6c8ebf", "#000000"),
    "dx_gw":     ("#dae8fc", "#6c8ebf", "#000000"),
    "dx_vif":    ("#dae8fc", "#6c8ebf", "#000000"),
    "secret":    ("#f5f5f5", "#999999", "#000000"),
    "ssm":       ("#f5f5f5", "#999999", "#000000"),
    "iam":       ("#f5f5f5", "#999999", "#000000"),
    "cf":        ("#dae8fc", "#6c8ebf", "#000000"),
    "ebs":       ("#fff2cc", "#d6b656", "#000000"),
    "default":   ("#ffffff", "#999999", "#000000"),
}

RTYPE_KEY = {
    "VPC":                     "vpc",
    "Subnet":                  "sub_pub",
    "Internet Gateway":        "igw",
    "NAT Gateway":             "natgw",
    "Elastic IP":              "eip",
    "Route Table":             "rtb",
    "Security Group":          "sg",
    "EC2 Instance":            "ec2",
    "EBS Volume":              "ebs",
    "Load Balancer":           "alb",
    "ECS Cluster":             "ecs",
    "EKS Cluster":             "eks",
    "Lambda Function":         "lambda",
    "RDS Instance":            "rds",
    "RDS Cluster":             "rds",
    "ElastiCache":             "ecache",
    "DynamoDB Table":          "dynamo",
    "S3 Bucket":               "s3",
    "SNS Topic":               "sns",
    "SQS Queue":               "sqs",
    "Secret":                  "secret",
    "SSM Parameter":           "ssm",
    "IAM User":                "iam",
    "CloudFront":              "cf",
    "Transit Gateway":         "tgw",
    "TGW Attachment":          "tgw_att",
    "TGW Route Table":         "tgw_rtb",
    "Customer Gateway":        "cgw",
    "Virtual Private Gateway": "vgw",
    "VPN Connection":          "vpn",
    "DX Connection":           "dx_conn",
    "DX Gateway":              "dx_gw",
    "DX Virtual Interface":    "dx_vif",
}

# ══════════════════════════════════════════════════════════════════════════════
#  LAYOUT CONSTANTS
# ══════════════════════════════════════════════════════════════════════════════
NW,  NH  = 200, 60    # node card width / height
NGX, NGY = 16,  12    # node gap x / y
SNX, SNY = 22,  36    # subnet inner pad x / y (top = header)
SNG      = 16         # gap between sibling subnets
VPX, VPY = 26,  34    # vpc inner pad x / y (below header)
VPG      = 18         # gap between subnets row and vpc-level cards row
VPH      = 30         # vpc header height
RPX, RPY = 30,  50    # region pad x / y
RGY      = 40         # gap between regions
COLS_SN  = 3          # max cards per row inside a subnet
COLS_VPC = 4          # max cards per row in vpc-level section
COLS_RL  = 5          # max cards per row in region-level section

EDGE_BASE = (
    "edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;"
    "jettySize=auto;fontSize=9;fontColor=#444444;strokeColor=#6c8ebf;"
    "strokeWidth=1.5;exitX=0.5;exitY=0.5;exitDx=0;exitDy=0;"
    "entryX=0.5;entryY=0.5;entryDx=0;entryDy=0;"
)
EDGE_SOLID  = EDGE_BASE
EDGE_DASHED = EDGE_BASE + "dashed=1;dashPattern=8 4;"

# ══════════════════════════════════════════════════════════════════════════════
#  SMALL UTILITIES
# ══════════════════════════════════════════════════════════════════════════════
_uid = 1
def uid():
    global _uid; _uid += 1; return str(_uid)

def trunc(s, n=26):
    s = s or ""; return s if len(s) <= n else s[:n-1]+"…"

def parse_attrs(s):
    out = {}
    for p in (s or "").split(","):
        if "=" in p:
            k,v = p.split("=",1); out[k.strip()] = v.strip()
    return out

SKIP_VALS = {"","none","N/A","detached","unassociated","false","true","0","null"}
def split_ids(v):
    return [t.strip() for t in (v or "").split(",")
            if t.strip() and t.strip() not in SKIP_VALS]

def pal(key, extra=""):
    f,s,fc = PAL.get(key, PAL["default"])
    return (f"rounded=1;whiteSpace=wrap;html=1;arcSize=6;"
            f"fillColor={f};strokeColor={s};fontColor={fc};"
            f"fontSize=10;align=center;verticalAlign=middle;"+extra)

def lane(key, start=28):
    f,s,fc = PAL.get(key, PAL["default"])
    return (f"swimlane;fontStyle=1;fontSize=11;startSize={start};html=1;"
            f"fillColor={f};strokeColor={s};fontColor={fc};"
            f"rounded=1;arcSize=3;swimlaneLine=1;align=center;")

def card_label(rtype, name, rid, state):
    return (f"<b>{trunc(rtype,22)}</b><br/>"
            f"{trunc(name or rid,26)}<br/>"
            f"<font color='#666'>{trunc(state,20)}</font>")

def tooltip(r):
    return (f"Type:  {r.get('ResourceType','')}\n"
            f"ID:    {r.get('ResourceID','')}\n"
            f"Name:  {r.get('Name','')}\n"
            f"Region:{r.get('Region','')}\n"
            f"State: {r.get('State','')}\n"
            f"ARN:   {r.get('ARN','')}\n"
            f"Attrs: {r.get('AdditionalAttributes','')}")

# ══════════════════════════════════════════════════════════════════════════════
#  XML EMIT HELPERS
# ══════════════════════════════════════════════════════════════════════════════
def mk_cell(root_el, cid, label, style, x, y, w, h, parent, tip=""):
    c = ET.SubElement(root_el, "mxCell",
        id=cid, value=label, style=style, vertex="1", parent=parent)
    if tip: c.set("tooltip", tip)
    ET.SubElement(c, "mxGeometry",
        x=str(int(x)), y=str(int(y)), width=str(int(w)), height=str(int(h)),
        **{"as":"geometry"})
    return c

def mk_edge(root_el, src, tgt, label="", dashed=False, parent="1"):
    if not src or not tgt or src==tgt: return
    ET.SubElement(root_el, "mxCell",
        id=uid(), value=label,
        style=EDGE_DASHED if dashed else EDGE_SOLID,
        edge="1", source=src, target=tgt, parent=parent,
        **{"mxGeometry":""})
    # mxGeometry must be a child element
    e = root_el.findall("mxCell")[-1]
    ET.SubElement(e, "mxGeometry", relative="1", **{"as":"geometry"})

# ══════════════════════════════════════════════════════════════════════════════
#  SIZING HELPERS
# ══════════════════════════════════════════════════════════════════════════════
def grid_size(n_items, cols):
    """Return (width, height) of a grid of n_items cards with given cols."""
    if n_items == 0: return 0, 0
    c = min(n_items, cols)
    r = math.ceil(n_items / c)
    w = c*(NW+NGX) - NGX
    h = r*(NH+NGY) - NGY
    return w, h

def subnet_size(n_children):
    """Outer size of a subnet swimlane given n children."""
    c = min(max(n_children,1), COLS_SN)
    r = math.ceil(max(n_children,1)/c)
    w = SNX*2 + c*(NW+NGX) - NGX
    h = SNY + r*(NH+NGY) + NGY
    return w, h

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
def build_drawio(rows):

    # ── Indexes ────────────────────────────────────────────────────────────
    by_id   = {r["ResourceID"]: r for r in rows}
    by_name = {}
    for r in rows:
        nm = r.get("Name","")
        if nm and nm not in by_name:
            by_name[nm] = r

    A = {r["ResourceID"]: parse_attrs(r.get("AdditionalAttributes","")) for r in rows}

    def resolve(v):
        if not v or v in SKIP_VALS: return None
        if v in by_id:   return v
        if v in by_name: return by_name[v]["ResourceID"]
        return None

    # Map ResourceID → draw.io cell id (filled as we emit cells)
    C = {}   # ResourceID → cell_id

    # Deferred edges: list of (src_rid, dst_rid, label, dashed)
    edges = []
    seen_edges = set()

    def defer(src, dst, label="", dashed=False):
        if not src or not dst or src==dst: return
        k = (src, dst, label)
        if k not in seen_edges:
            seen_edges.add(k)
            edges.append((src, dst, label, dashed))

    # ── Group by region ────────────────────────────────────────────────────
    by_region = defaultdict(list)
    for r in rows:
        by_region[r.get("Region","global") or "global"].append(r)

    # ── XML root ───────────────────────────────────────────────────────────
    root = ET.Element("mxGraphModel",
        dx="1422",dy="762",grid="1",gridSize="10",guides="1",tooltips="1",
        connect="1",arrows="1",fold="1",page="1",pageScale="1",
        pageWidth="1654",pageHeight="1169",math="0",shadow="0")
    doc = ET.SubElement(root,"root")
    ET.SubElement(doc,"mxCell",id="0")
    ET.SubElement(doc,"mxCell",id="1",parent="0")

    canvas_y = 10

    # ══════════════════════════════════════════════════════════════════════
    #  PER-REGION LAYOUT
    # ══════════════════════════════════════════════════════════════════════
    for region in sorted(by_region.keys()):
        rrows = by_region[region]

        def oftype(*types):
            return [r for r in rrows if r["ResourceType"] in types]

        # --- classify ---
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
        sns_list  = oftype("SNS Topic")
        sqs_list  = oftype("SQS Queue")
        secrets   = oftype("Secret")
        ssm_list  = oftype("SSM Parameter")
        s3_list   = oftype("S3 Bucket")
        iam_list  = oftype("IAM User")
        cf_list   = oftype("CloudFront")
        tgws      = oftype("Transit Gateway")
        tgw_atts  = oftype("TGW Attachment")
        tgw_rtbs  = oftype("TGW Route Table")
        cgws      = oftype("Customer Gateway")
        vgws      = oftype("Virtual Private Gateway")
        vpn_conns = oftype("VPN Connection")
        dx_conns  = oftype("DX Connection")
        dx_gws    = oftype("DX Gateway")
        dx_vifs   = oftype("DX Virtual Interface")

        # --- helper lookups ---
        def subnet_vpc(sid):  return A[sid].get("VPC","")
        def subnet_is_pub(sid): return A[sid].get("PublicIP","false").lower()=="true"

        # EIP: alloc-id IS the ResourceID per the inventory script
        eip_by_alloc = {e["ResourceID"]: e for e in eips}
        eip_by_inst  = {}
        for e in eips:
            inst = A[e["ResourceID"]].get("Instance","")
            if inst: eip_by_inst[inst] = e

        # NAT GW → alloc_id
        nat_alloc = {n["ResourceID"]: A[n["ResourceID"]].get("AllocationId","")
                     for n in natgws}
        # alloc_id → NAT GW rid
        alloc_nat = {v: k for k,v in nat_alloc.items() if v}

        # EIP → NAT GW
        eip_nat = {}
        for eid, erow in eip_by_alloc.items():
            if eid in alloc_nat:
                eip_nat[eid] = alloc_nat[eid]

        # Children of each subnet
        def ec2_in(sid):   return [r for r in ec2s   if A[r["ResourceID"]].get("Subnet","")==sid]
        def nat_in(sid):   return [r for r in natgws  if A[r["ResourceID"]].get("Subnet","")==sid]
        def lam_in(sid):   return [r for r in lambdas if A[r["ResourceID"]].get("Subnet","")==sid]
        def eip_for_subnet(sid):
            out=[]
            # EIPs bound to EC2 in this subnet
            for ec in ec2_in(sid):
                if ec["ResourceID"] in eip_by_inst:
                    out.append(eip_by_inst[ec["ResourceID"]])
            # EIPs bound to NAT GW in this subnet
            for nat in nat_in(sid):
                alloc = A[nat["ResourceID"]].get("AllocationId","")
                if alloc and alloc in eip_by_alloc:
                    e = eip_by_alloc[alloc]
                    if e not in out: out.append(e)
            return out

        def vpc_of(rid, key="VPC"): return A[rid].get(key,"")

        # Resources tied to a VPC but not a specific subnet
        def vpc_level(vpc_id):
            return (
                [r for r in igws   if vpc_of(r["ResourceID"])  ==vpc_id] +
                [r for r in sgs    if vpc_of(r["ResourceID"])  ==vpc_id] +
                [r for r in rtbs   if vpc_of(r["ResourceID"])  ==vpc_id] +
                [r for r in lbs    if vpc_of(r["ResourceID"])  ==vpc_id] +
                [r for r in rdsi   if vpc_of(r["ResourceID"])  ==vpc_id] +
                [r for r in rdsc   if vpc_of(r["ResourceID"])  ==vpc_id] +
                [r for r in ecs_list if vpc_of(r["ResourceID"])== vpc_id] +
                [r for r in eks_list if vpc_of(r["ResourceID"])== vpc_id] +
                [r for r in vgws   if A[r["ResourceID"]].get("VPC","")== vpc_id] +
                # Lambda with VPC but no Subnet attr
                [r for r in lambdas
                 if vpc_of(r["ResourceID"])==vpc_id
                 and not A[r["ResourceID"]].get("Subnet","")]
            )

        # Region-level (not VPC-bound) resources
        placed_in_vpc = set()  # filled after VPC loop

        # ── Measure VPC heights before drawing region ──────────────────────
        def measure_vpc(vpc_id):
            v_sn = [s for s in subnets if subnet_vpc(s["ResourceID"])==vpc_id]
            sn_hs = []
            sn_ws = []
            for sn in v_sn:
                sid = sn["ResourceID"]
                ch  = ec2_in(sid)+nat_in(sid)+lam_in(sid)+eip_for_subnet(sid)
                w,h = subnet_size(len(ch))
                sn_ws.append(w); sn_hs.append(h)
            sub_row_w = sum(sn_ws)+SNG*(len(v_sn)-1) if v_sn else 0
            sub_row_h = max(sn_hs) if sn_hs else 0

            vl = vpc_level(vpc_id)
            vl_w, vl_h = grid_size(len(vl), COLS_VPC)

            w = max(sub_row_w, vl_w) + VPX*2
            h = VPH + VPY + sub_row_h + (VPG+vl_h if vl else 0) + VPX
            return max(w, 320), max(h, 120)

        vpc_sizes = {v["ResourceID"]: measure_vpc(v["ResourceID"]) for v in vpcs}

        # ── Region total size ──────────────────────────────────────────────
        total_vpc_h = sum(h for _,h in vpc_sizes.values()) + max(0,len(vpcs)-1)*VPG
        max_vpc_w   = max((w for w,_ in vpc_sizes.values()), default=0)

        # Region-level cards (measured later, placeholder width)
        rl_placeholder_w = COLS_RL*(NW+NGX)

        region_w = max(max_vpc_w, rl_placeholder_w) + RPX*2
        # Height estimate (region-level cards added at bottom)
        region_h_est = RPY + total_vpc_h + RPY*2 + 200  # 200 for rl cards

        # ── Emit region swimlane ───────────────────────────────────────────
        region_cid = uid()
        mk_cell(doc, region_cid,
                f"Region: {region}",
                lane("region", start=32),
                10, canvas_y, region_w, region_h_est, "1")

        cur_y = RPY  # y-cursor inside region

        # ══════════════════════════════════════════════════════════════════
        #  VPC SWIMLANES
        # ══════════════════════════════════════════════════════════════════
        for vpc_row in vpcs:
            vid = vpc_row["ResourceID"]
            vw, vh = vpc_sizes[vid]
            vw = max(vw, region_w - RPX*2)

            vpc_cid = uid()
            C[vid] = vpc_cid
            placed_in_vpc.add(vid)

            va = A[vid]
            vpc_lbl = (f"<b>VPC</b>  {trunc(vpc_row.get('Name','') or vid,28)}"
                       f"  <font color='#345'>{va.get('CIDR','')}</font>")
            mk_cell(doc, vpc_cid, vpc_lbl, lane("vpc", start=28),
                    RPX, cur_y, vw, vh, region_cid, tip=tooltip(vpc_row))

            # y-cursor inside VPC (below header)
            vy = VPH + VPY - 10

            # ── Subnets ───────────────────────────────────────────────────
            v_subnets = [s for s in subnets if subnet_vpc(s["ResourceID"])==vid]
            sx_cursor = VPX

            for sn in v_subnets:
                sid    = sn["ResourceID"]
                is_pub = subnet_is_pub(sid)
                sa     = A[sid]
                ch     = ec2_in(sid)+nat_in(sid)+lam_in(sid)+eip_for_subnet(sid)
                sw, sh = subnet_size(len(ch))

                sn_cid = uid()
                C[sid] = sn_cid
                placed_in_vpc.add(sid)

                sn_lbl = (f"<b>{'Public' if is_pub else 'Private'} Subnet</b>"
                          f"  {trunc(sn.get('Name','') or sid,20)}<br/>"
                          f"<font color='#555'>{sa.get('CIDR','')}  "
                          f"{sa.get('AZ','')}</font>")
                mk_cell(doc, sn_cid, sn_lbl,
                        lane("sub_pub" if is_pub else "sub_priv", start=34),
                        sx_cursor, vy, sw, sh, vpc_cid, tip=tooltip(sn))

                # Place children inside subnet
                for idx, ch_row in enumerate(ch):
                    crid = ch_row["ResourceID"]
                    if crid in C: continue   # already placed (e.g. EIP seen twice)
                    ci   = idx % COLS_SN
                    ri   = idx // COLS_SN
                    cx_  = SNX + ci*(NW+NGX)
                    cy_  = SNY + ri*(NH+NGY)
                    ccid = uid()
                    C[crid] = ccid
                    placed_in_vpc.add(crid)
                    sk = ("sub_pub" if is_pub else "sub_priv") if ch_row["ResourceType"]=="Subnet" \
                         else RTYPE_KEY.get(ch_row["ResourceType"],"default")
                    mk_cell(doc, ccid,
                            card_label(ch_row["ResourceType"],
                                       ch_row.get("Name",""), crid,
                                       ch_row.get("State","")),
                            pal(sk), cx_, cy_, NW, NH, sn_cid, tip=tooltip(ch_row))

                sx_cursor += sw + SNG

            # Subnets row height
            sub_row_h = max(
                (subnet_size(len(ec2_in(s["ResourceID"])+nat_in(s["ResourceID"])+
                              lam_in(s["ResourceID"])+eip_for_subnet(s["ResourceID"])))[1]
                 for s in v_subnets), default=0)

            # ── VPC-level cards ───────────────────────────────────────────
            vl = [r for r in vpc_level(vid) if r["ResourceID"] not in C]
            vl_y = vy + sub_row_h + (VPG if v_subnets else 0)
            cols_vl = min(max(len(vl),1), COLS_VPC)

            for idx, row in enumerate(vl):
                rid = row["ResourceID"]
                if rid in C: continue
                ci  = idx % cols_vl
                ri  = idx // cols_vl
                fx  = VPX + ci*(NW+NGX)
                fy  = vl_y + ri*(NH+NGY)
                cid5 = uid()
                C[rid] = cid5
                placed_in_vpc.add(rid)
                mk_cell(doc, cid5,
                        card_label(row["ResourceType"],
                                   row.get("Name",""), rid, row.get("State","")),
                        pal(RTYPE_KEY.get(row["ResourceType"],"default")),
                        fx, fy, NW, NH, vpc_cid, tip=tooltip(row))

            cur_y += vh + VPG

        # ══════════════════════════════════════════════════════════════════
        #  REGION-LEVEL CARDS  (outside any VPC)
        # ══════════════════════════════════════════════════════════════════
        rl = [r for r in rrows if r["ResourceID"] not in placed_in_vpc
              and r["ResourceID"] not in C]

        # Also add global resources if this is the global region
        cols_rl2 = min(max(len(rl),1), COLS_RL)
        for idx, row in enumerate(rl):
            rid = row["ResourceID"]
            if rid in C: continue
            ci  = idx % cols_rl2
            ri  = idx // cols_rl2
            rx  = RPX + ci*(NW+NGX)
            ry  = cur_y + ri*(NH+NGY)
            cid6 = uid()
            C[rid] = cid6
            mk_cell(doc, cid6,
                    card_label(row["ResourceType"],
                               row.get("Name",""), rid, row.get("State","")),
                    pal(RTYPE_KEY.get(row["ResourceType"],"default")),
                    rx, ry, NW, NH, region_cid, tip=tooltip(row))

        # Update region height now we know content
        rows_rl2 = math.ceil(max(len(rl),1)/cols_rl2) if rl else 0
        actual_h = cur_y + rows_rl2*(NH+NGY) + RPY
        # Patch region swimlane height
        for cell in doc.findall(f"mxCell[@id='{region_cid}']"):
            geo = cell.find("mxGeometry")
            if geo is not None:
                geo.set("height", str(int(actual_h)))

        canvas_y += actual_h + RGY

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
            if alloc:
                defer(rid, resolve(alloc) or alloc, "uses EIP", dashed=True)

        elif rtype == "Elastic IP":
            inst = a.get("Instance","")
            if inst: defer(rid, resolve(inst), "EIP →", dashed=True)
            # EIP → NAT GW
            if rid in eip_nat:
                defer(rid, eip_nat[rid], "EIP →", dashed=True)

        elif rtype == "TGW Attachment":
            tgw_rid = a.get("TGW","")
            att_typ = a.get("Type","")
            res_rid = a.get("Resource","")
            defer(rid, resolve(tgw_rid), f"→ TGW ({att_typ})")
            defer(rid, resolve(res_rid), f"attaches {att_typ}")
            # Also direct edge between the resource and TGW
            defer(resolve(res_rid), resolve(tgw_rid), att_typ)

        elif rtype == "TGW Route Table":
            defer(rid, resolve(a.get("TGW","")), "RTB of TGW")

        elif rtype == "VPN Connection":
            defer(rid, resolve(a.get("CGW","")), "→ CGW")
            vgw = a.get("VGW",""); tgw = a.get("TGW","")
            if resolve(vgw): defer(rid, resolve(vgw), "→ VGW")
            if resolve(tgw): defer(rid, resolve(tgw), "→ TGW")

        elif rtype == "DX Virtual Interface":
            defer(rid, resolve(a.get("Connection","")), "via DX conn")
            defer(rid, resolve(a.get("DXGateway","")), "→ DX GW")

        elif rtype == "DX Gateway":
            # Link to TGW through TGW attachment records
            for att in tgw_atts:
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
                defer(rid, resolve(sn), "spans subnet", dashed=True)

        elif rtype in ("RDS Instance","RDS Cluster"):
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

    # ── Flush deferred edges ───────────────────────────────────────────────
    emitted = set()
    for (src_rid, dst_rid, label, dashed) in edges:
        sc = C.get(src_rid)
        dc = C.get(dst_rid)
        if not sc or not dc or sc==dc: continue
        key = (sc, dc, label)
        if key in emitted: continue
        emitted.add(key)
        mk_edge(doc, sc, dc, label, dashed)

    # ══════════════════════════════════════════════════════════════════════
    #  SERIALISE
    # ══════════════════════════════════════════════════════════════════════
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

    out_path = sys.argv[2] if len(sys.argv)>=3 else csv_path.replace(".csv",".drawio")
    if not out_path.endswith(".drawio"): out_path += ".drawio"

    rows = []
    with open(csv_path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if row.get("ResourceType","").strip() in ("","ResourceType"): continue
            rows.append(row)

    if not rows:
        print("ERROR: No resources found in CSV."); sys.exit(1)

    print(f"  Loaded {len(rows)} resources from {csv_path}")
    for rtype,n in sorted(Counter(r["ResourceType"] for r in rows).items()):
        print(f"    {n:4d}  {rtype}")

    xml = build_drawio(rows)
    with open(out_path,"w",encoding="utf-8") as fh:
        fh.write(xml)

    kb = os.path.getsize(out_path)//1024
    print(f"\n  Diagram written → {out_path}  ({kb} KB)")
    print()
    print("  Open in draw.io Desktop or https://app.diagrams.net")
    print("  → File → Open from → Device → select the .drawio file")
    print()
    print("  Tips once open:")
    print("    Ctrl+Shift+H   Fit entire diagram on screen")
    print("    Ctrl+Shift+F   Search for a resource by name or ID")
    print("    Arrange → Layout → Organic   for auto-layout")

if __name__ == "__main__":
    main()
