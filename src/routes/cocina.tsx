import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { ArrowLeft, Bell, BellOff } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useRealtime } from "@/hooks/use-realtime";
import { Button } from "@/components/ui/button";
import { horaMty } from "@/lib/catalogo";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/cocina")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Cocina KDS — Tacos el Faro" },
      { name: "description", content: "Pantalla de comandas de cocina en tiempo real." },
      { property: "og:title", content: "Cocina KDS — Tacos el Faro" },
      { property: "og:description", content: "Pantalla de comandas de cocina en tiempo real." },
    ],
  }),
  component: Cocina,
});

const siguiente: Record<string, { estado: string; label: string; cls: string }> = {
  pendiente: { estado: "preparacion", label: "Empezar", cls: "bg-warning text-warning-foreground hover:bg-warning/90" },
  preparacion: { estado: "listo", label: "Listo", cls: "bg-success text-success-foreground hover:bg-success/90" },
};

function beep() {
  try {
    const ctx = new AudioContext();
    [0, 0.25].forEach((t) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.frequency.value = 880;
      o.connect(g); g.connect(ctx.destination);
      g.gain.setValueAtTime(0.3, ctx.currentTime + t);
      o.start(ctx.currentTime + t);
      o.stop(ctx.currentTime + t + 0.18);
    });
  } catch { /* audio no disponible */ }
}

function Cocina() {
  const [sonido, setSonido] = useState(false);
  const [flash, setFlash] = useState(false);
  const sonidoRef = useRef(sonido);
  sonidoRef.current = sonido;

  useRealtime(() => {
    if (sonidoRef.current) beep();
    setFlash(true);
    setTimeout(() => setFlash(false), 1500);
  });

  const q = useQuery({
    queryKey: ["kds"],
    queryFn: async () => {
      const desde = new Date(Date.now() - 12 * 3600_000).toISOString();
      const { data } = await supabase
        .from("comandas")
        .select("id,numero,estado,created_at,mesas(nombre),comanda_items(id,nombre,cantidad,modificadores,notas,estacion)")
        .in("estado", ["pendiente", "preparacion"])
        .gte("created_at", desde)
        .order("created_at");
      return (data ?? [])
        .map((c) => ({ ...c, comanda_items: c.comanda_items.filter((i) => i.estacion === "cocina") }))
        .filter((c) => c.comanda_items.length > 0);
    },
  });

  async function avanzar(id: string, estado: string) {
    await supabase.from("comandas").update({ estado }).eq("id", id);
    q.refetch();
  }

  return (
    <main className={cn("min-h-screen p-4 transition-colors", flash && "bg-primary/20")}>
      <header className="flex items-center gap-3 mb-4">
        <Link to="/" aria-label="Inicio"><ArrowLeft /></Link>
        <h1 className="font-display text-5xl flex-1">Cocina</h1>
        <span className="text-muted-foreground">{q.data?.length ?? 0} en cola</span>
        <Button variant={sonido ? "default" : "secondary"} onClick={() => { setSonido(!sonido); if (!sonido) beep(); }}>
          {sonido ? <Bell /> : <BellOff />} {sonido ? "Sonido activo" : "Activar sonido"}
        </Button>
      </header>
      {q.data?.length === 0 && <p className="text-center text-2xl text-muted-foreground py-24">Sin comandas pendientes 🔥</p>}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
        {q.data?.map((c) => {
          const sig = siguiente[c.estado] ?? siguiente["preparacion"]!;
          return (
            <article key={c.id} className={cn("rounded-2xl border-4 bg-card flex flex-col", c.estado === "pendiente" ? "border-primary" : "border-warning")}>
              <div className="flex justify-between items-baseline p-4 border-b">
                <span className="font-display text-5xl">#{c.numero}</span>
                <div className="text-right">
                  <p className="font-display text-3xl">{(c.mesas as { nombre: string } | null)?.nombre}</p>
                  <p className="text-muted-foreground">{horaMty(c.created_at)}</p>
                </div>
              </div>
              <ul className="p-4 space-y-3 flex-1">
                {c.comanda_items.map((i) => (
                  <li key={i.id}>
                    <p className="text-2xl font-bold"><span className="text-primary">{i.cantidad}×</span> {i.nombre}</p>
                    {Array.isArray(i.modificadores) && i.modificadores.length > 0 && (
                      <p className="text-lg font-semibold text-warning">{(i.modificadores as string[]).join(" · ")}</p>
                    )}
                    {i.notas && <p className="text-lg font-semibold bg-destructive/20 text-foreground rounded px-2 mt-1">⚠ {i.notas}</p>}
                  </li>
                ))}
              </ul>
              <button onClick={() => avanzar(c.id, sig.estado)} className={cn("h-16 text-2xl font-display rounded-b-xl", sig.cls)}>
                {c.estado === "pendiente" ? "Pendiente → " : "En preparación → "}{sig.label}
              </button>
            </article>
          );
        })}
      </div>
    </main>
  );
}
