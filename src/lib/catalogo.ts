export const CARNES = ["Asada", "Pastor", "Tripa"] as const;

export const CATEGORIAS = [
  "Tacos",
  "Quesadillas",
  "Especiales",
  "Papas y Frijoles",
  "Tortas",
  "Postres y Bebidas",
] as const;

export type Carne = (typeof CARNES)[number];
export type Categoria = (typeof CATEGORIAS)[number];
export type ModSeleccionado = { grupo: string; nombre: string; extra: number };

export type OpcionModificador = { id: string; nombre: string; extra: number };
export type GrupoModificadores = {
  id: string;
  nombre: string;
  requerido?: boolean;
  tipo: "uno" | "varios";
  opciones: OpcionModificador[];
};

export type Producto = {
  id: string;
  nombre: string;
  categoria: Categoria;
  precio: number;
  mixta?: { extraTripaPrincipal: number; extraQueso?: number };
  grupos?: GrupoModificadores[];
};

export const PRODUCTOS: Producto[] = [
  { id: "taco-maiz", nombre: "Taco maíz", categoria: "Tacos", precio: 40, mixta: { extraTripaPrincipal: 5, extraQueso: 5 } },
  { id: "taco-harina", nombre: "Taco harina", categoria: "Tacos", precio: 42, mixta: { extraTripaPrincipal: 5, extraQueso: 5 } },
  { id: "quesadilla-maiz", nombre: "Quesadilla maíz", categoria: "Quesadillas", precio: 65, mixta: { extraTripaPrincipal: 10 } },
  { id: "quesadilla-harina", nombre: "Quesadilla harina", categoria: "Quesadillas", precio: 95, mixta: { extraTripaPrincipal: 10 } },
  { id: "vampiro", nombre: "Vampiro", categoria: "Especiales", precio: 75, mixta: { extraTripaPrincipal: 10 } },
  { id: "chorreada", nombre: "Chorreada", categoria: "Especiales", precio: 80, mixta: { extraTripaPrincipal: 10 } },
  { id: "costra", nombre: "Costra de queso", categoria: "Especiales", precio: 100 },
  { id: "gaonera", nombre: "Gaonera", categoria: "Especiales", precio: 75 },
  { id: "chilaca", nombre: "Taco de Chile chilaca", categoria: "Especiales", precio: 80 },
  { id: "papa-especial", nombre: "Papa asada especial", categoria: "Papas y Frijoles", precio: 180, mixta: { extraTripaPrincipal: 10 } },
  { id: "papa-sencilla", nombre: "Papa sencilla", categoria: "Papas y Frijoles", precio: 130 },
  { id: "charros-especiales", nombre: "Charros especiales", categoria: "Papas y Frijoles", precio: 75 },
  { id: "charros-sencillos", nombre: "Charros sencillos", categoria: "Papas y Frijoles", precio: 55 },
  { id: "torta", nombre: "Torta", categoria: "Tortas", precio: 130, mixta: { extraTripaPrincipal: 10 } },
  { id: "hamburguesa", nombre: "Hamburguesa", categoria: "Tortas", precio: 125 },
  { id: "quesagloria", nombre: "Quesagloria", categoria: "Postres y Bebidas", precio: 100 },
  { id: "agua-natural", nombre: "Agua natural", categoria: "Postres y Bebidas", precio: 15 },
  { id: "agua-sabor", nombre: "Agua de sabor 1L", categoria: "Postres y Bebidas", precio: 45 },
  { id: "horchata", nombre: "Horchata y cebada 1L", categoria: "Postres y Bebidas", precio: 50 },
  { id: "topo-chico", nombre: "Topo Chico", categoria: "Postres y Bebidas", precio: 35 },
  { id: "toni-col", nombre: "ToniCol", categoria: "Postres y Bebidas", precio: 55 },
];

export const NOTAS_RAPIDAS = [
  "Con todo",
  "Natural",
  "Sin salsa de tomate",
  "Sin lechuga",
  "Sin frijoles",
  "Bien cocida",
];

export function modsMixta(
  producto: Producto,
  principal: Carne,
  extras: Carne[],
  queso: boolean,
): ModSeleccionado[] {
  if (!producto.mixta) return [];

  const carnesExtra = [...new Set(extras)].filter((carne) => carne !== principal);

  return [
    {
      grupo: "carne",
      nombre: principal,
      extra: principal === "Tripa" ? producto.mixta.extraTripaPrincipal : 0,
    },
    ...carnesExtra.map((carne) => ({
      grupo: "carne-extra",
      nombre: `+ ${carne}`,
      extra: 10,
    })),
    ...(queso && producto.mixta.extraQueso !== undefined
      ? [{ grupo: "queso", nombre: "Con queso", extra: producto.mixta.extraQueso }]
      : []),
  ];
}

export function precioUnitario(producto: Producto, mods: ModSeleccionado[]): number {
  return producto.precio + mods.reduce((total, modificador) => total + modificador.extra, 0);
}

export const mxn = (n: number) =>
  new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN" }).format(n);

export function hoyMonterrey(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Monterrey" }).format(new Date());
}

export const horaMty = (iso: string) =>
  new Intl.DateTimeFormat("es-MX", {
    timeZone: "America/Monterrey",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(iso));
