-- Tiny demo table so the pipeline has something to read
CREATE TABLE IF NOT EXISTS items(
  id serial PRIMARY KEY,
  name text,
  price numeric
);
INSERT INTO items(name, price)
VALUES ('apple',1.2),('banana',0.8),('carrot',0.5)
ON CONFLICT DO NOTHING;
