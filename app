import streamlit as st
from dataclasses import dataclass, field
from typing import List, Optional, Literal, Dict, Any

Metering = Literal["BETB", "FETB", "NONE"]

@dataclass
class LeafItem:
    name: str
    metering: Metering  # BETB / FETB / NONE
    enabled: bool = True
    capacity_tb: float = 0.0      # used only if metering != NONE
    unit_cost_per_tb: float = 0.0 # optional helper for BETB/FETB
    flat_cost: float = 0.0        # always available
    notes: str = ""

    def total_cost(self) -> float:
        metered_part = (self.capacity_tb * self.unit_cost_per_tb) if self.metering != "NONE" else 0.0
        return round(metered_part + self.flat_cost, 2)

@dataclass
class SupportTier:
    name: str
    cost: float = 0.0

@dataclass
class Edition:
    name: str
    tiers: List[SupportTier] = field(default_factory=list)
    enabled: bool = False
    # Editions are *functional* choices; one active at a time per subscription
    active_tier: Optional[str] = None

@dataclass
class SubscriptionBlock:
    name: str
    metering: Metering
    capacity_tb: float = 0.0
    unit_cost_per_tb: float = 0.0
    flat_cost: float = 0.0
    editions: List[Edition] = field(default_factory=list)
    enabled: bool = True

    def total_cost(self) -> float:
        base = (self.capacity_tb * self.unit_cost_per_tb) if self.metering != "NONE" else 0.0
        base += self.flat_cost
        # add selected edition+tier cost
        for ed in self.editions:
            if ed.enabled and ed.active_tier:
                for t in ed.tiers:
                    if t.name == ed.active_tier:
                        base += t.cost
        return round(base, 2)

@dataclass
class CopyNode:
    name: str
    immutable: bool = True
    enabled: bool = True
    # leaf items
    leaves: List[LeafItem] = field(default_factory=list)
    # special subscription block that includes editions/tiers (on-prem subscription)
    subscription: Optional[SubscriptionBlock] = None
    # nested cloud capacity leaves (common pattern)
    cloud_backup: Optional[LeafItem] = None
    cloud_archive: Optional[LeafItem] = None

    def total_cost(self) -> float:
        total = 0.0
        if not self.enabled:
            return 0.0
        for lf in self.leaves:
            if lf.enabled:
                total += lf.total_cost()
        if self.subscription and self.subscription.enabled:
            total += self.subscription.total_cost()
        if self.cloud_backup and self.cloud_backup.enabled:
            total += self.cloud_backup.total_cost()
        if self.cloud_archive and self.cloud_archive.enabled:
            total += self.cloud_archive.total_cost()
        return round(total, 2)

@dataclass
class OptionNode:
    name: str
    enabled: bool = True
    copies: List[CopyNode] = field(default_factory=list)

    def total_cost(self) -> float:
        if not self.enabled:
            return 0.0
        return round(sum(c.total_cost() for c in self.copies if c.enabled), 2)

@dataclass
class WorkloadNode:
    name: str
    enabled: bool = True
    options: List[OptionNode] = field(default_factory=list)  # for NAS we have A/B; for VMs we keep single OptionNode "VM"
    # Convenience: if no options (like VM), we’ll put everything in one option called "VM"

    def total_cost(self) -> float:
        if not self.enabled:
            return 0.0
        if self.options:
            return round(sum(o.total_cost() for o in self.options if o.enabled), 2)
        return 0.0

# ---------- Define the decision tree schema ----------
def default_tree() -> List[WorkloadNode]:
    # Support tiers for editions
    foundation = Edition(
        name="Foundation Edition",
        tiers=[SupportTier("Basic"), SupportTier("Premium")]
    )
    enterprise = Edition(
        name="Enterprise Edition",
        tiers=[SupportTier("Basic"), SupportTier("Premium")]
    )

    # VM Workloads: Copy1/Copy3 on-prem; Copy2 cloud
    vm = WorkloadNode(
        name="VM Workloads",
        options=[
            OptionNode(
                name="VM",
                copies=[
                    CopyNode(
                        name="Copy 1 (Primary, Immutable)",
                        leaves=[
                            LeafItem("On-Prem Hardware", metering="BETB"),
                            LeafItem("Hardware Maintenance", metering="NONE"),
                        ],
                        subscription=SubscriptionBlock(
                            name="Subscription License",
                            metering="BETB",
                            editions=[foundation, enterprise]
                        )
                    ),
                    CopyNode(
                        name="Copy 2 (Secondary, Immutable)",
                        cloud_backup=LeafItem("Cloud Backup Capacity", metering="BETB"),
                        cloud_archive=LeafItem("Cloud Archive Capacity", metering="BETB")
                    ),
                    CopyNode(
                        name="Copy 3 (Tertiary, Immutable)",
                        leaves=[
                            LeafItem("On-Prem Hardware", metering="BETB"),
                            LeafItem("Hardware Maintenance", metering="NONE"),
                        ],
                        subscription=SubscriptionBlock(
                            name="Subscription License",
                            metering="BETB",
                            editions=[foundation, enterprise]
                        )
                    ),
                ]
            )
        ]
    )

    # NAS Option A (Traditional) and Option B (Modern Cloud-Only)
    nas_option_a = OptionNode(
        name="Option A: Traditional (with On-Prem)",
        copies=[
            CopyNode(
                name="Copy 1 (Primary, Immutable)",
                leaves=[
                    LeafItem("On-Prem Hardware", metering="BETB"),
                    LeafItem("Hardware Maintenance", metering="NONE"),
                ],
                subscription=SubscriptionBlock(
                    name="Subscription License",
                    metering="BETB",
                    editions=[Edition("Foundation Edition", [SupportTier("Basic"), SupportTier("Premium")]),
                             Edition("Enterprise Edition", [SupportTier("Basic"), SupportTier("Premium")])]
                ),
                cloud_backup=LeafItem("Backup Cloud Capacity", metering="BETB")
            ),
            CopyNode(
                name="Copy 2 (Secondary, Immutable)",
                cloud_backup=LeafItem("Cloud Backup Capacity", metering="BETB"),
                cloud_archive=LeafItem("Cloud Archive Capacity", metering="BETB")
            ),
            CopyNode(
                name="Copy 3 (Tertiary, Immutable)",
                leaves=[
                    LeafItem("On-Prem Hardware", metering="BETB"),
                    LeafItem("Hardware Maintenance", metering="NONE"),
                ],
                subscription=SubscriptionBlock(
                    name="Subscription License",
                    metering="BETB",
                    editions=[Edition("Foundation Edition", [SupportTier("Basic"), SupportTier("Premium")]),
                             Edition("Enterprise Edition", [SupportTier("Basic"), SupportTier("Premium")])]
                )
            ),
        ]
    )

    nas_option_b = OptionNode(
        name="Option B: Modern / Cloud-Only (No On-Prem)",
        copies=[
            CopyNode(
                name="Copy 1 (Primary Cloud Copy, Immutable)",
                cloud_backup=LeafItem("Cloud Backup Capacity", metering="BETB"),
                cloud_archive=LeafItem("Cloud Archive Capacity", metering="BETB"),
            ),
            CopyNode(
                name="Copy 2 (Secondary Cloud Copy, Immutable)",
                cloud_backup=LeafItem("Cloud Backup Capacity", metering="BETB"),
                cloud_archive=LeafItem("Cloud Archive Capacity", metering="BETB"),
            ),
            CopyNode(
                name="NAS Cloud Direct (CD)",
                leaves=[],
                subscription=SubscriptionBlock(
                    name="Subscription License (NAS CD)",
                    metering="FETB",
                    editions=[],
                )
            ),
        ]
    )

    nas = WorkloadNode(
        name="Unstructured / NAS Workloads",
        options=[nas_option_a, nas_option_b]
    )

    return [vm, nas]

# ---------- UI helpers ----------
def currency(x: float) -> str:
    return f"${x:,.2f}"

def render_leaf(prefix: str, leaf: LeafItem):
    col1, col2, col3, col4 = st.columns([2.5, 1.2, 1.2, 1.2])
    with col1:
        leaf.enabled = st.checkbox(f"{prefix}{leaf.name}", value=leaf.enabled, key=f"{prefix}{leaf.name}_en")
    with col2:
        if leaf.metering != "NONE":
            leaf.capacity_tb = st.number_input("Capacity (TB)", min_value=0.0, value=leaf.capacity_tb, step=1.0, key=f"{prefix}{leaf.name}_cap")
        else:
            st.write(" ")
    with col3:
        if leaf.metering != "NONE":
            leaf.unit_cost_per_tb = st.number_input("Unit $/TB", min_value=0.0, value=leaf.unit_cost_per_tb, step=1.0, key=f"{prefix}{leaf.name}_unit")
        else:
            st.write(" ")
    with col4:
        leaf.flat_cost = st.number_input("Flat $", min_value=0.0, value=leaf.flat_cost, step=1.0, key=f"{prefix}{leaf.name}_flat")
    st.caption(f"Line Total: **{currency(leaf.total_cost())}**")

def render_subscription(prefix: str, sub: SubscriptionBlock):
    sub.enabled = st.checkbox(f"{prefix}{sub.name}", value=sub.enabled, key=f"{prefix}{sub.name}_en")
    if not sub.enabled:
        return
    c1, c2, c3 = st.columns([1.2, 1.2, 1.2])
    with c1:
        if sub.metering != "NONE":
            sub.capacity_tb = st.number_input("Capacity (TB)", min_value=0.0, value=sub.capacity_tb, step=1.0, key=f"{prefix}{sub.name}_cap")
    with c2:
        if sub.metering != "NONE":
            sub.unit_cost_per_tb = st.number_input("Unit $/TB", min_value=0.0, value=sub.unit_cost_per_tb, step=1.0, key=f"{prefix}{sub.name}_unit")
    with c3:
        sub.flat_cost = st.number_input("Flat $", min_value=0.0, value=sub.flat_cost, step=1.0, key=f"{prefix}{sub.name}_flat")

    # Editions (one active)
    if sub.editions:
        st.markdown("**Edition & Support Tier**")
        ed_names = [e.name for e in sub.editions]
        selected = st.radio("Choose Edition", ed_names, horizontal=True, key=f"{prefix}{sub.name}_edition")
        for ed in sub.editions:
            ed.enabled = (ed.name == selected)
            if ed.enabled:
                tier_names = [t.name for t in ed.tiers]
                if tier_names:
                    ed.active_tier = st.radio("Support Tier", tier_names, horizontal=True, key=f"{prefix}{sub.name}_{ed.name}_tier")
                    # Costs per tier
                    tt_cols = st.columns(len(ed.tiers))
                    for idx, t in enumerate(ed.tiers):
                        with tt_cols[idx]:
                            t.cost = st.number_input(f"{t.name} Cost $", min_value=0.0, value=t.cost, step=1.0, key=f"{prefix}{sub.name}_{ed.name}_{t.name}_cost")

    st.caption(f"Block Total: **{currency(sub.total_cost())}**")

def render_copy(prefix: str, cp: CopyNode):
    cp.enabled = st.checkbox(f"{prefix}{cp.name}", value=cp.enabled, key=f"{prefix}{cp.name}_en")
    if not cp.enabled:
        return
    st.write("")
    # Leaves (On-prem HW, Maintenance)
    for lf in cp.leaves:
        render_leaf(prefix + cp.name + " > ", lf)

    # Subscription (On-Prem License w/ Editions/Tiers)
    if cp.subscription:
        render_subscription(prefix + cp.name + " > ", cp.subscription)

    # Cloud leaves (if present)
    if cp.cloud_backup:
        render_leaf(prefix + cp.name + " > ", cp.cloud_backup)
    if cp.cloud_archive:
        render_leaf(prefix + cp.name + " > ", cp.cloud_archive)

    st.success(f"{cp.name} Total = {currency(cp.total_cost())}")

def main():
    st.set_page_config(page_title="Backup Solution Configurator", layout="wide")
    st.title("Backup Solution Configurator")
    st.caption("Toggle options, enter capacities & costs. Immutability is assumed across copies.")

    if "tree" not in st.session_state:
        st.session_state["tree"] = default_tree()

    tree: List[WorkloadNode] = st.session_state["tree"]

    grand_total = 0.0
    for wl in tree:
        with st.expander(f"🔹 {wl.name}", expanded=True):
            wl.enabled = st.checkbox(f"Enable {wl.name}", value=wl.enabled, key=f"{wl.name}_en")
            if not wl.enabled:
                continue

            # If the workload has options (NAS A/B) render them; if not (VM), render the single option it has
            opts = wl.options if wl.options else []
            if not opts:
                st.info("No options defined.")
                continue

            for opt in opts:
                opt.enabled = st.checkbox(f"**{opt.name}**", value=opt.enabled, key=f"{wl.name}_{opt.name}_en")
                if not opt.enabled:
                    continue

                st.divider()
                for cp in opt.copies:
                    render_copy(f"{wl.name} > {opt.name} > ", cp)

                opt_total = opt.total_cost()
                st.subheader(f"{opt.name} Subtotal: {currency(opt_total)}")

            wl_total = wl.total_cost()
            grand_total += wl_total
            st.header(f"{wl.name} Total: {currency(wl_total)}")

    st.markdown("---")
    st.title(f"Grand Total: {currency(grand_total)}")

    # Optional: export summary
    if st.button("Export Summary (JSON)"):
        import json
        def to_json(obj: Any) -> Any:
            if isinstance(obj, list):
                return [to_json(x) for x in obj]
            if hasattr(obj, "__dict__"):
                d = obj.__dict__.copy()
                return {k: to_json(v) for k, v in d.items()}
            return obj
        st.download_button(
            "Download JSON",
            data=str(to_json(tree)),
            file_name="backup_config_summary.json",
            mime="application/json"
        )

if __name__ == "__main__":
    main()
