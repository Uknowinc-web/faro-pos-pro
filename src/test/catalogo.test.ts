import assert from "node:assert/strict";
import test from "node:test";
import {
  CATEGORIAS,
  PRODUCTOS,
  modsMixta,
  precioUnitario,
  type Carne,
} from "../lib/catalogo";

test("el catálogo contiene productos únicos con categorías y precios válidos", () => {
  const ids = PRODUCTOS.map((producto) => producto.id);

  assert.equal(new Set(ids).size, ids.length);
  assert.ok(PRODUCTOS.length > 0);
  assert.ok(
    PRODUCTOS.every(
      (producto) =>
        producto.nombre.trim().length > 0 &&
        CATEGORIAS.includes(producto.categoria) &&
        Number.isFinite(producto.precio) &&
        producto.precio >= 0,
    ),
  );
});

test("el precio suma el cargo de tripa cuando es la carne principal", () => {
  const taco = PRODUCTOS.find((producto) => producto.id === "taco-maiz");
  const quesadilla = PRODUCTOS.find((producto) => producto.id === "quesadilla-maiz");
  assert.ok(taco);
  assert.ok(quesadilla);

  assert.equal(precioUnitario(taco, modsMixta(taco, "Tripa", [], false)), 45);
  assert.equal(precioUnitario(quesadilla, modsMixta(quesadilla, "Tripa", [], false)), 75);
});

test("cada carne agregada cuesta $10 y no duplica la carne principal", () => {
  const taco = PRODUCTOS.find((producto) => producto.id === "taco-maiz");
  assert.ok(taco);
  const modificadores = modsMixta(taco, "Asada", ["Asada", "Pastor"], false);

  assert.deepEqual(
    modificadores.map((modificador) => modificador.nombre),
    ["Asada", "+ Pastor"],
  );
  assert.equal(precioUnitario(taco, modificadores), 50);
});

test("una carne agregada de tripa solo cobra la mezcla si no es principal", () => {
  const taco = PRODUCTOS.find((producto) => producto.id === "taco-maiz");
  assert.ok(taco);

  assert.equal(precioUnitario(taco, modsMixta(taco, "Asada", ["Tripa"], false)), 50);
  assert.equal(precioUnitario(taco, modsMixta(taco, "Tripa", ["Asada"], false)), 55);
});

test("dos carnes agregadas suman $20", () => {
  const torta = PRODUCTOS.find((producto) => producto.id === "torta");
  assert.ok(torta);

  assert.equal(precioUnitario(torta, modsMixta(torta, "Tripa", ["Asada", "Pastor"], false)), 160);
});

test("los ejemplos de mezcla coinciden con la lista de precios", () => {
  const casos: {
    productoId: string;
    principal: Carne;
    extras: Carne[];
    queso?: boolean;
    esperado: number;
  }[] = [
    { productoId: "papa-especial", principal: "Tripa", extras: ["Asada"], esperado: 200 },
    { productoId: "vampiro", principal: "Tripa", extras: ["Pastor"], esperado: 95 },
    { productoId: "chorreada", principal: "Tripa", extras: ["Asada"], esperado: 100 },
    { productoId: "quesadilla-harina", principal: "Pastor", extras: ["Tripa", "Asada"], esperado: 115 },
    { productoId: "quesadilla-maiz", principal: "Asada", extras: ["Tripa", "Pastor"], esperado: 85 },
  ];

  for (const caso of casos) {
    const producto = PRODUCTOS.find((item) => item.id === caso.productoId);
    assert.ok(producto, `Falta el producto ${caso.productoId}`);
    assert.equal(
      precioUnitario(producto, modsMixta(producto, caso.principal, caso.extras, caso.queso ?? false)),
      caso.esperado,
      caso.productoId,
    );
  }
});

test("los productos no mixeables no reciben modificadores de carne", () => {
  const bebida = PRODUCTOS.find((producto) => producto.id === "agua-natural");
  assert.ok(bebida);

  assert.deepEqual(modsMixta(bebida, "Asada", ["Pastor"], true), []);
});

test("el queso suma $5 en tacos y no se ofrece en otros mixteables", () => {
  const taco = PRODUCTOS.find((producto) => producto.id === "taco-harina");
  const quesadilla = PRODUCTOS.find((producto) => producto.id === "quesadilla-maiz");
  assert.ok(taco);
  assert.ok(quesadilla);

  const tacoMods = modsMixta(taco, "Asada", ["Pastor", "Tripa"], true);
  assert.equal(precioUnitario(taco, tacoMods), 67);
  assert.ok(tacoMods.some((modificador) => modificador.nombre === "Con queso"));
  assert.ok(!modsMixta(quesadilla, "Asada", [], true).some((modificador) => modificador.nombre === "Con queso"));
});

test("solo los productos indicados permiten mezclar carnes", () => {
  const mixteables = new Set([
    "taco-maiz",
    "taco-harina",
    "quesadilla-maiz",
    "quesadilla-harina",
    "vampiro",
    "chorreada",
    "papa-especial",
    "torta",
  ]);

  assert.deepEqual(
    PRODUCTOS.filter((producto) => producto.mixta).map((producto) => producto.id).sort(),
    [...mixteables].sort(),
  );
});

test("el catálogo ya no divide productos por estación", () => {
  assert.ok(PRODUCTOS.every((producto) => !("estacion" in producto)));
});
