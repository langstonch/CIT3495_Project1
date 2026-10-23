# Production image. The C3 baseline is Dockerfile.baseline.
FROM node:22-alpine AS deps
WORKDIR /w
COPY package*.json ./
RUN npm install --omit=dev --omit=optional --no-audit --no-fund

FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /w/node_modules node_modules
COPY package.json app.js index.js ./
USER node
EXPOSE 3002
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:3002/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node","index.js"]
