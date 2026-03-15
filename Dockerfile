FROM node:20-bookworm

WORKDIR /lab2

COPY package*.json ./
RUN npm install

COPY . .

CMD ["npm", "test"]
