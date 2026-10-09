import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";
import { ArrowLeft, Banknote, CreditCard, Plus, Receipt, XCircle } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useRealtime } from "@/hooks/use-realtime";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { hoyMonterrey, horaMty, mxn } from "@/lib/catalogo";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/caja")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Caja — Tacos el Faro" },
      { name: "description", content: "Cuentas activas, cobro y corte de caja diario." },
      { property: "og:title", content: "Caja — Tacos el Faro" },
      { property: "og:description", content: "Cuentas activas, cobro y corte de caja diario." },
    ],
  }),
  component: Caja,
});

const estiloMesa: Record<string, string> = {
  disponible: "border-border text-muted-foreground",
  ocupada: "border-primary bg-primary/10",
  por_cobrar: "border-warning bg-warning/15",
};

function Caja() {
  useRealtime();
  return (
    <main className="min-h-screen p-4 md:p-6">
      <header className="flex items-center gap-3 mb-4">
        <Link to="/" aria-label="Inicio"><ArrowLeft /></Link>
        <h1 className="font-display text-5xl">Caja</h1>
      </header>
      <Tabs defaultValue="mesas">
        <TabsList><TabsTrigger value="mesas">Mesas activas</TabsTrigger><TabsTrigger value="corte">Corte de caja</TabsTrigger></TabsList>
        <TabsContent value="mesas"><Mesas /></TabsContent>
        <TabsContent value="corte"><Corte /></TabsContent>
      </Tabs>
    </main>
  );
}

function Mesas() {
  const [sel, setSel] = useState<string | null>(null);
  const [nueva, setNueva] = useState("");
  const mesas = useQuery({
    queryKey: ["caja-mesas"],
    queryFn: async () => {
      const [{ data: ms }, { data: cs }] = await Promise.all([
        supabase.from("mesas").select("id,nombre,estado,orden").order("orden").order("nombre"),
        supabase.from("cuentas").select("id,mesa_id,comandas(comanda_items(cantidad,precio_unitario))").in("estado", ["abierta", "por_cobrar"]),
      ]);
      return (ms ?? []).map((m) => {
        const c = cs?.find((x) => x.mesa_id === m.id);
        const total = c?.comandas.flatMap((k) => k.comanda_items).reduce((s, i) => s + i.cantidad * Number(i.precio_unitario), 0) ?? 0;
        return { ...m, cuentaId: c?.id ?? null, total };
      });
    },
  });

  async function agregarMesa() {
    if (!nueva.trim()) return;
    const { error } = await supabase.from("mesas").insert({ nombre: nueva.trim(), orden: 50 });
    if (error) { toast.error(error.code === "23505" ? "Ya existe esa mesa" : error.message); return; }
    setNueva("");
    mesas.refetch();
  }

  const actual = mesas.data?.find((m) => m.id === sel);

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_420px] mt-4">
      <div>
        <div className="grid grid-cols-3 sm:grid-cols-4 xl:grid-cols-5 gap-3">
          {mesas.data?.map((m) => (
            <button key={m.id} onClick={() => setSel(m.id)} className={cn("rounded-xl border-2 bg-card p-4 h-28 text-left transition", estiloMesa[m.estado], sel === m.id && "ring-2 ring-ring")}>
              <p className="font-display text-2xl text-foreground">{m.nombre}</p>
              <p className="text-xs capitalize">{m.estado.replace("_", " ")}</p>
              {m.cuentaId && <p className="font-semibold text-foreground mt-1">{mxn(m.total)}</p>}
            </button>
          ))}
        </div>
        <div className="flex gap-2 mt-4 max-w-sm">
          <Input value={nueva} onChange={(e) => setNueva(e.target.value)} placeholder="Nueva mesa (ej. Terraza 1)" />
          <Button onClick={agregarMesa}><Plus /> Agregar</Button>
        </div>
      </div>
      <aside className="rounded-2xl border bg-card p-5 h-fit lg:sticky lg:top-4">
        {actual?.cuentaId ? <Cuenta cuentaId={actual.cuentaId} mesa={actual.nombre} estado={actual.estado} onDone={() => setSel(null)} />
          : <p className="text-muted-foreground text-center py-12">{actual ? `${actual.nombre} está disponible.` : "Selecciona una mesa con cuenta abierta."}</p>}
      </aside>
    </div>
  );
}

function Cuenta({ cuentaId, mesa, estado, onDone }: { cuentaId: string; mesa: string; estado: string; onDone: () => void }) {
  const [anular, setAnular] = useState(false);
  const [motivo, setMotivo] = useState("");
  const [busy, setBusy] = useState(false);
  const q = useQuery({
    queryKey: ["cuenta", cuentaId],
    queryFn: async () =>
      (await supabase.from("comandas").select("id,numero,created_at,comanda_items(id,nombre,cantidad,precio_unitario,modificadores)").eq("cuenta_id", cuentaId).order("created_at")).data ?? [],
  });
  const items = q.data?.flatMap((c) => c.comanda_items) ?? [];
  const total = items.reduce((s, i) => s + i.cantidad * Number(i.precio_unitario), 0);

  async function rpc(fn: "cobrar_cuenta" | "solicitar_cuenta" | "anular_cuenta", args: Record<string, string>, ok: string) {
    setBusy(true);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await supabase.rpc(fn, args as any);
    setBusy(false);
    if (error) { toast.error(error.message); return; }
    toast.success(ok);
    if (fn !== "solicitar_cuenta") onDone();
  }

  return (
    <div>
      <div className="flex justify-between items-baseline">
        <h2 className="font-display text-4xl">{mesa}</h2>
        <span className="text-sm text-muted-foreground">{q.data?.length ?? 0} comandas</span>
      </div>
      <div className="mt-4 space-y-2 max-h-[45vh] overflow-y-auto">
        {q.data?.map((c) => (
          <div key={c.id}>
            <p className="text-xs text-muted-foreground">#{c.numero} · {horaMty(c.created_at)}</p>
            {c.comanda_items.map((i) => (
              <div key={i.id} className="flex justify-between py-1 border-b border-border/50">
                <div>
                  <p>{i.cantidad}× {i.nombre}</p>
                  {Array.isArray(i.modificadores) && i.modificadores.length > 0 && <p className="text-xs text-muted-foreground">{(i.modificadores as string[]).join(", ")}</p>}
                </div>
                <span className="tabular-nums">{mxn(i.cantidad * Number(i.precio_unitario))}</span>
              </div>
            ))}
          </div>
        ))}
      </div>
      <div className="flex justify-between items-baseline mt-4">
        <span className="text-muted-foreground">Total</span>
        <span className="font-display text-5xl text-primary">{mxn(total)}</span>
      </div>
      <div className="grid grid-cols-2 gap-2 mt-4">
        {estado !== "por_cobrar" && (
          <Button variant="secondary" className="col-span-2 h-12" disabled={busy} onClick={() => rpc("solicitar_cuenta", { p_cuenta: cuentaId }, "Mesa marcada por cobrar")}><Receipt /> Marcar por cobrar</Button>
        )}
        <Button className="h-14" disabled={busy} onClick={() => rpc("cobrar_cuenta", { p_cuenta: cuentaId, p_metodo: "efectivo" }, "Cobrado en efectivo")}><Banknote /> Efectivo</Button>
        <Button className="h-14 bg-info text-info-foreground hover:bg-info/90" disabled={busy} onClick={() => rpc("cobrar_cuenta", { p_cuenta: cuentaId, p_metodo: "clip" }, "Cobrado con Clip")}><CreditCard /> Clip</Button>
        <Button variant="ghost" className="col-span-2 text-destructive" onClick={() => setAnular(true)}><XCircle /> Anular cuenta</Button>
      </div>
      <Dialog open={anular} onOpenChange={setAnular}>
        <DialogContent>
          <DialogHeader><DialogTitle>Anular cuenta de {mesa}</DialogTitle></DialogHeader>
          <p className="text-sm text-muted-foreground">La cuenta no se contará en ventas. Escribe el motivo.</p>
          <Input value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Motivo de anulación" />
          <DialogFooter>
            <Button variant="destructive" disabled={!motivo.trim() || busy} onClick={async () => { await rpc("anular_cuenta", { p_cuenta: cuentaId, p_motivo: motivo }, "Cuenta anulada"); setAnular(false); setMotivo(""); }}>Confirmar anulación</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function Corte() {
  const [fecha, setFecha] = useState(hoyMonterrey());
  const q = useQuery({
    queryKey: ["corte", fecha],
    queryFn: async () =>
      (await supabase.from("cuentas").select("id,estado,metodo_pago,total,comandas(comanda_items(nombre,cantidad,precio_unitario))").eq("fecha_operativa", fecha).in("estado", ["pagada", "anulada"])).data ?? [],
  });
  const pagadas = q.data?.filter((c) => c.estado === "pagada") ?? [];
  const anuladas = (q.data?.length ?? 0) - pagadas.length;
  const total = pagadas.reduce((s, c) => s + Number(c.total ?? 0), 0);
  const porMetodo = (m: string) => pagadas.filter((c) => c.metodo_pago === m).reduce((s, c) => s + Number(c.total ?? 0), 0);
  const top = new Map<string, { cant: number; monto: number }>();
  pagadas.flatMap((c) => c.comandas.flatMap((k) => k.comanda_items)).forEach((i) => {
    const t = top.get(i.nombre) ?? { cant: 0, monto: 0 };
    t.cant += i.cantidad; t.monto += i.cantidad * Number(i.precio_unitario);
    top.set(i.nombre, t);
  });
  const ranking = [...top.entries()].sort((a, b) => b[1].cant - a[1].cant).slice(0, 10);

  const kpis = [
    { l: "Total vendido", v: mxn(total) },
    { l: "Efectivo", v: mxn(porMetodo("efectivo")) },
    { l: "Clip", v: mxn(porMetodo("clip")) },
    { l: "Ticket promedio", v: mxn(pagadas.length ? total / pagadas.length : 0) },
    { l: "Cuentas cobradas", v: String(pagadas.length) },
    { l: "Anuladas", v: String(anuladas) },
  ];

  return (
    <div className="mt-4 space-y-6">
      <div className="flex items-center gap-3">
        <label className="text-sm text-muted-foreground">Fecha operativa (Monterrey)</label>
        <Input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} className="w-auto" />
      </div>
      <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
        {kpis.map((k) => (
          <div key={k.l} className="rounded-2xl border bg-card p-5">
            <p className="text-sm text-muted-foreground">{k.l}</p>
            <p className="font-display text-4xl">{k.v}</p>
          </div>
        ))}
      </div>
      <div className="rounded-2xl border bg-card p-5">
        <h3 className="font-display text-3xl mb-3">Top productos</h3>
        {ranking.length === 0 ? <p className="text-muted-foreground">Sin ventas en esta fecha.</p> : (
          <table className="w-full text-left">
            <thead className="text-sm text-muted-foreground"><tr><th>Producto</th><th className="text-right">Piezas</th><th className="text-right">Monto</th></tr></thead>
            <tbody>{ranking.map(([n, t]) => (
              <tr key={n} className="border-t"><td className="py-2">{n}</td><td className="text-right">{t.cant}</td><td className="text-right tabular-nums">{mxn(t.monto)}</td></tr>
            ))}</tbody>
          </table>
        )}
      </div>
    </div>
  );
}
