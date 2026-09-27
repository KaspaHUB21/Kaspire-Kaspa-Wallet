import handler from "./dist/server/index.js";

export default {
  fetch(request, env, ctx) {
    return handler(request, env, ctx);
  },
};
