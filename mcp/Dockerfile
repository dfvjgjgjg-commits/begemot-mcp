FROM node:22-alpine

WORKDIR /app

# deps first for layer caching
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

# runtime: core + http transport + config
COPY core.mjs server-http.mjs config.json ./

ENV PORT=8788 \
    HOST=0.0.0.0

EXPOSE 8788

# No shell execution is reachable in this image: server-http.mjs is built with
# allowShell=false, so run_code is not even registered.
CMD ["node", "server-http.mjs"]
