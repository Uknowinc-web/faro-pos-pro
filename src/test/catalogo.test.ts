import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";
import { ArrowLeft, Minus, Plus, Send, Trash2 } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useRealtime } from "@/hooks/use-realtime";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { CATEGORIAS, NOTAS_RAPIDAS, PRODUCTOS, precioUnitario, horaMty, type ModSeleccionado, type Producto } from "@/lib/catalogo";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/mesero")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Mesero — Tacos el Faro" },
      { name: "description", content: "Toma de comandas para meseros de Tacos el Faro." },
      { property: "og:title", content: "Mesero — Tacos el Faro" },
      { property: "og:description", content: "Toma de comandas para meseros de Tacos el Faro." },
    ],
  }),
  component: Mesero,
});

type Linea = { key: string; producto: Producto; cantidad: number; mods: ModSeleccionado[]; notas: string };

const estadoMesa: Record<string, string> = {
  disponible: "border-border",
  ocupada: "border-primary bg-primary/10",
  por_cobrar: "border-warning bg-warning/10",
};
const estadoComanda: Record<string, string> = {
  pendiente: "bg-muted text-foreground",
  preparacion: "bg-warning text-warning-foreground",
  listo: "bg-success text-success-foreground",
};
const etiquetaComanda: Record<string, string> = { pendiente: "Pendiente", preparacion: "En preparación", listo: "Listo" };

function Mesero() {
  useRealtime();
  const [mesa, setMesa] = useState<{ id: string; nombre: string } | null>(null);
  const [cat, setCat] = useState<string>(CATEGORIAS[0]);
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [token, setToken] = useState(() => crypto.randomUUID());
  const [enviando, setEnviando] = useState(false);
  const [editar, setEditar] = useState<Producto | null>(null);
  const [vista, setVista] = useState<"mesas" | "ordenes">("mesas");

  const mesas = useQuery({
    queryKey: ["mesas"],
    queryFn: async () => (await supabase.from("mesas").select("id,nombre,estado,orden").order("orden").order("nombre")).data ?? [],
  });
  const ordenes = useQuery({
    queryKey: ["mesero-ordenes"],
    queryFn: async () => {
      const desde = new Date(Date.now() - 12 * 3600_000).toISOString();
      return (
        (await supabase
          .from("comandas")
          .select("id,numero,estado,created_at,mesas(nombre),comanda_items(cantidad,nombre)")
          .gte("created_at", desde)
          .order("created_at", { ascending: false })).data ?? []
      );
    },
  });

  const totalPiezas = lineas.reduce((s, l) => s + l.cantidad, 0);

  async function enviar() {
    if (!mesa || lineas.length === 0 || enviando) return;
    setEnviando(true);
    const items = lineas.map((l) => ({
      producto_id: l.producto.id,
      nombre: l.producto.nombre,
      cantidad: l.cantidad,
      precio_unitario: precioUnitario(l.producto, l.mods),
      modificadores: l.mods.map((m) => m.nombre),
      notas: l.notas,
      estacion: l.producto.estacion,
    }));
    const { error } = await supabase.rpc("enviar_comanda", { p_mesa: mesa.id, p_token: token, p_items: items });
    setEnviando(false);
    if (error) { toast.error("No se pudo enviar: " + error.message); return; }
    toast.success(`Comanda enviada · ${mesa.nombre}`);
    setLineas([]);
    setToken(crypto.randomUUID());
    setMesa(null);
  }

  if (!mesa) {
    return (
      <main className="min-h-screen pb-24 max-w-xl mx-auto">
        <header className="flex items-center gap-3 p-4">
          <Link to="/" aria-label="Inicio"><ArrowLeft /></Link>
          <h1 className="font-display text-4xl">Mesero</h1>
        </header>
        <div className="flex gap-2 px-4">
          {(["mesas", "ordenes"] as const).map((v) => (
            <Button key={v} variant={vista === v ? "default" : "secondary"} className="flex-1 h-12" onClick={() => setVista(v)}>
              {v === "mesas" ? "Mesas" : "Mis órdenes"}
            </Button>
          ))}
        </div>
        {vista === "mesas" ? (
          <div className="grid grid-cols-3 gap-3 p-4">
            {mesas.data?.map((m) => (
              <button key={m.id} onClick={() => setMesa(m)} className={cn("rounded-xl border-2 bg-card h-24 flex flex-col items-center justify-center active:scale-95 transition", estadoMesa[m.estado])}>
                <span className="font-display text-2xl">{m.nombre}</span>
                <span className="text-xs text-muted-foreground capitalize">{m.estado.replace("_", " ")}</span>
              </button>
            ))}
          </div>
        ) : (
          <div className="space-y-3 p-4">
            {ordenes.data?.length === 0 && <p className="text-muted-foreground text-center py-8">Sin órdenes recientes.</p>}
            {ordenes.data?.map((o) => (
              <div key={o.id} className="rounded-xl border bg-card p-4">
                <div className="flex justify-between items-center">
                  <span className="font-display text-2xl">#{o.numero} · {(o.mesas as { nombre: string } | null)?.nombre}</span>
                  <span className={cn("rounded-full px-3 py-1 text-xs font-semibold", estadoComanda[o.estado])}>{etiquetaComanda[o.estado]}</span>
                </div>
                <p className="text-sm text-muted-foreground mt-1">
                  {horaMty(o.created_at)} · {o.comanda_items.map((i) => `${i.cantidad} ${i.nombre}`).join(", ")}
                </p>
              </div>
            ))}
          </div>
        )}
      </main>
    );
  }

  const productos = PRODUCTOS.filter((p) => p.categoria === cat);

  return (
    <main className="min-h-screen pb-40 max-w-xl mx-auto">
      <header className="sticky top-0 z-10 bg-background/95 backdrop-blur border-b">
        <div className="flex items-center gap-3 p-4">
          <button onClick={() => setMesa(null)} aria-label="Volver"><ArrowLeft /></button>
          <h1 className="font-display text-4xl">{mesa.nombre}</h1>
        </div>
        <div className="flex gap-2 overflow-x-auto px-4 pb-3">
          {CATEGORIAS.map((c) => (
            <Button key={c} size="sm" variant={c === cat ? "default" : "secondary"} onClick={() => setCat(c)} className="shrink-0">{c}</Button>
          ))}
        </div>
      </header>
      <div className="grid grid-cols-2 gap-3 p-4">
        {productos.map((p) => (
          <button key={p.id} onClick={() => setEditar(p)} className="rounded-xl border bg-card min-h-20 p-3 text-left active:scale-95 transition">
            <span className="font-semibold">{p.nombre}</span>
            {p.estacion === "barra" && <span className="block text-xs text-info">Barra</span>}
          </button>
        ))}
      </div>

      {lineas.length > 0 && (
        <section className="px-4 space-y-2">
          <h2 className="font-display text-2xl">Comanda</h2>
          {lineas.map((l) => (
            <div key={l.key} className="rounded-xl border bg-card p-3 flex items-center gap-2">
              <div className="flex-1 min-w-0">
                <p className="font-semibold">{l.producto.nombre}</p>
                {(l.mods.length > 0 || l.notas) && (
                  <p className="text-xs text-primary">{[...l.mods.map((m) => m.nombre), l.notas].filter(Boolean).join(" · ")}</p>
                )}
              </div>
              <Button size="icon" variant="secondary" onClick={() => setLineas((ls) => ls.map((x) => (x.key === l.key ? { ...x, cantidad: Math.max(1, x.cantidad - 1) } : x)))}><Minus /></Button>
              <span className="w-6 text-center font-bold">{l.cantidad}</span>
              <Button size="icon" variant="secondary" onClick={() => setLineas((ls) => ls.map((x) => (x.key === l.key ? { ...x, cantidad: x.cantidad + 1 } : x)))}><Plus /></Button>
              <Button size="icon" variant="ghost" onClick={() => setLineas((ls) => ls.filter((x) => x.key !== l.key))} aria-label="Quitar"><Trash2 /></Button>
            </div>
          ))}
        </section>
      )}

      <div className="fixed bottom-0 inset-x-0 p-4 bg-background/95 border-t">
        <Button className="w-full h-14 text-lg max-w-xl mx-auto flex" disabled={lineas.length === 0 || enviando} onClick={enviar}>
          <Send /> {enviando ? "Enviando…" : `Enviar a cocina (${totalPiezas})`}
        </Button>
      </div>

      <EditorProducto
        producto={editar}
        onClose={() => setEditar(null)}
        onAdd={(l) => setLineas((ls) => [...ls, l])}
      />
    </main>
  );
}

function EditorProducto({ producto, onClose, onAdd }: { producto: Producto | null; onClose: () => void; onAdd: (l: Linea) => void }) {
  const [sel, setSel] = useState<Record<string, string[]>>({});
  const [notas, setNotas] = useState<string[]>([]);
  const [libre, setLibre] = useState("");
  const [cantidad, setCantidad] = useState(1);

  const reset = () => { setSel({}); setNotas([]); setLibre(""); setCantidad(1); };
  const faltan = producto?.grupos?.some((g) => g.requerido && !(sel[g.id]?.length)) ?? false;

  function agregar() {
    if (!producto) return;
    const mods: ModSeleccionado[] = [];
    producto.grupos?.forEach((g) => g.opciones.forEach((o) => sel[g.id]?.includes(o.id) && mods.push({ grupo: g.id, nombre: o.nombre.replace(/ \(\+\d+\)/, ""), extra: o.extra })));
    onAdd({ key: crypto.randomUUID(), producto, cantidad, mods, notas: [...notas, libre.trim()].filter(Boolean).join(", ") });
    reset();
    onClose();
  }

  return (
    <Sheet open={!!producto} onOpenChange={(o) => { if (!o) { reset(); onClose(); } }}>
      <SheetContent side="bottom" className="max-h-[90vh] overflow-y-auto rounded-t-2xl">
        <SheetHeader><SheetTitle className="font-display text-3xl">{producto?.nombre}</SheetTitle></SheetHeader>
        <div className="space-y-5 px-4 pb-4">
          {producto?.grupos?.map((g) => (
            <div key={g.id}>
              <p className="text-sm font-semibold mb-2">{g.nombre}{g.requerido && " *"}</p>
              <div className="flex flex-wrap gap-2">
                {g.opciones.map((o) => {
                  const on = sel[g.id]?.includes(o.id);
                  return (
                    <Button key={o.id} variant={on ? "default" : "secondary"} className="h-11"
                      onClick={() => setSel((s) => ({ ...s, [g.id]: g.tipo === "uno" ? [o.id] : on ? (s[g.id] ?? []).filter((x) => x !== o.id) : [...(s[g.id] ?? []), o.id] }))}>
                      {o.nombre.replace(/ \(\+\d+\)/, o.extra ? " extra" : "")}
                    </Button>
                  );
                })}
              </div>
            </div>
          ))}
          {producto?.estacion === "cocina" && (
            <div>
              <p className="text-sm font-semibold mb-2">Notas rápidas</p>
              <div className="flex flex-wrap gap-2">
                {NOTAS_RAPIDAS.map((n) => (
                  <Button key={n} variant={notas.includes(n) ? "default" : "secondary"} className="h-11"
                    onClick={() => setNotas((ns) => (ns.includes(n) ? ns.filter((x) => x !== n) : [...ns, n]))}>{n}</Button>
                ))}
              </div>
              <input value={libre} onChange={(e) => setLibre(e.target.value)} placeholder="Otra nota…" className="mt-3 w-full h-11 rounded-md border bg-input/30 px-3" />
            </div>
          )}
          <div className="flex items-center gap-3">
            <Button size="icon" variant="secondary" className="size-12" onClick={() => setCantidad((c) => Math.max(1, c - 1))}><Minus /></Button>
            <span className="font-display text-4xl w-10 text-center">{cantidad}</span>
            <Button size="icon" variant="secondary" className="size-12" onClick={() => setCantidad((c) => c + 1)}><Plus /></Button>
            <Button className="flex-1 h-12" disabled={faltan} onClick={agregar}>Agregar</Button>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  );
}
