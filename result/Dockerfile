FROM node:18-slim

ENV NODE_ENV=production

WORKDIR /app
COPY package*.json ./
RUN npm install --only=production && npm cache clean --force
COPY . . 

USER node
EXPOSE 4000

CMD ["node", "server.js"]