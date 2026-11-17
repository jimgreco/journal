import http from "node:http";
import { createApp, loadConfig } from "./app.js";
import { MemoryStore, PostgresStore } from "./store.js";

const config = loadConfig();
const store = config.databaseURL ? new PostgresStore(config.databaseURL) : new MemoryStore();
if (!config.databaseURL) console.warn("DATABASE_URL is not set: using an in-memory store (data is lost on restart)");

const server = http.createServer(createApp({ store, config }));
server.requestTimeout = 30_000;
server.headersTimeout = 15_000;
server.listen(config.port, () => console.log(`journal listening on :${config.port} (build ${config.build})`));

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    server.close(() => Promise.resolve(store.close?.()).finally(() => process.exit(0)));
    setTimeout(() => process.exit(0), 5_000).unref();
  });
}
