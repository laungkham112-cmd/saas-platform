#!/bin/bash
set -e

echo "💰 创建可赚钱 Shopify SaaS MVP..."

mkdir -p saas/server/src/routes
mkdir -p saas/server/src/middlewares
mkdir -p saas/server/src/utils
mkdir -p saas/server/public

# ================= ENV =================
cat > saas/server/.env << 'EOF'
DATABASE_URL=postgres://postgres:password@localhost:5432/saas
JWT_SECRET=shopify_money_secret

APP_URL=http://localhost:4000

STRIPE_KEY=your_stripe_key
OPENPAY_API_KEY=your_openpay_key
OPENPAY_BASE_URL=https://api.openpay.com
AIRWALLEX_KEY=your_airwallex_key
AIRWALLEX_BASE=https://api.airwallex.com
EOF

# ================= MAIN SERVER =================
cat > saas/server/src/main.js << 'EOF'
import express from "express";
import cors from "cors";
import dotenv from "dotenv";

import pay from "./routes/pay.js";
import dashboard from "./routes/dashboard.js";
import product from "./routes/product.js";
import cart from "./routes/cart.js";
import checkout from "./routes/checkout.js";

dotenv.config();

const app = express();
app.use(cors());
app.use(express.json());

app.use("/pay", pay);
app.use("/dashboard", dashboard);
app.use("/product", product);
app.use("/cart", cart);
app.use("/checkout", checkout);

// 前台
app.use(express.static("public"));

app.listen(4000, () => {
  console.log("💰 SaaS Running http://localhost:4000");
});
EOF

# ================= AUTH =================
cat > saas/server/src/middlewares/auth.js << 'EOF'
import jwt from "jsonwebtoken";

export default function auth(req, res, next) {
  const token = req.headers.authorization?.split(" ")[1];
  if (!token) return res.status(401).json({ error: "no token" });

  try {
    req.user = jwt.verify(token, process.env.JWT_SECRET);
    next();
  } catch {
    res.status(403).json({ error: "invalid token" });
  }
}
EOF

# ================= PAY (Stripe + 云汇 + OpenPay) =================
cat > saas/server/src/routes/pay.js << 'EOF'
import express from "express";
import Stripe from "stripe";
import axios from "axios";
import auth from "../middlewares/auth.js";

const router = express.Router();
const stripe = new Stripe(process.env.STRIPE_KEY);

router.post("/create", auth, async (req, res) => {
  const { method, amount } = req.body;

  // Stripe
  if (method === "stripe") {
    const session = await stripe.checkout.sessions.create({
      payment_method_types: ["card"],
      mode: "payment",
      line_items: [{
        price_data: {
          currency: "usd",
          product_data: { name: "Order" },
          unit_amount: amount * 100
        },
        quantity: 1
      }],
      success_url: process.env.APP_URL,
      cancel_url: process.env.APP_URL
    });

    return res.json({ url: session.url });
  }

  // OpenPay
  if (method === "openpay") {
    const r = await axios.post(
      process.env.OPENPAY_BASE_URL + "/payments",
      { amount },
      { headers: { Authorization: `Bearer ${process.env.OPENPAY_API_KEY}` } }
    );

    return res.json(r.data);
  }

  // Airwallex
  if (method === "airwallex") {
    const r = await axios.post(
      process.env.AIRWALLEX_BASE + "/api/v1/pa/payment_intents/create",
      {
        amount,
        currency: "USD"
      },
      {
        headers: { Authorization: `Bearer ${process.env.AIRWALLEX_KEY}` }
      }
    );

    return res.json(r.data);
  }

  res.status(400).json({ error: "invalid method" });
});

export default router;
EOF

# ================= DASHBOARD（赚钱核心） =================
cat > saas/server/src/routes/dashboard.js << 'EOF'
import express from "express";
import auth from "../middlewares/auth.js";

const router = express.Router();

// 模拟收入数据（可替换数据库）
router.get("/stats", auth, async (req, res) => {
  res.json({
    revenue: 1280,
    orders: 32
  });
});

export default router;
EOF

# ================= PRODUCT =================
cat > saas/server/src/routes/product.js << 'EOF'
import express from "express";

const router = express.Router();

const products = [
  { id: "1", name: "T-shirt", price: 20 },
  { id: "2", name: "Shoes", price: 60 }
];

router.get("/", (req, res) => {
  res.json(products);
});

export default router;
EOF

# ================= CART =================
cat > saas/server/src/routes/cart.js << 'EOF'
import express from "express";
const router = express.Router();

let cart = [];

router.post("/add", (req, res) => {
  cart.push(req.body);
  res.json(cart);
});

router.get("/", (req, res) => {
  res.json(cart);
});

export default router;
EOF

# ================= CHECKOUT =================
cat > saas/server/src/routes/checkout.js << 'EOF'
import express from "express";
const router = express.Router();

router.post("/", (req, res) => {
  res.json({
    orderId: "order_" + Date.now(),
    status: "pending"
  });
});

export default router;
EOF

# ================= FRONTEND（可卖货页面） =================
cat > saas/server/public/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>Shop SaaS</title>
</head>
<body>
  <h1>🛒 可赚钱商城</h1>

  <button onclick="load()">加载商品</button>
  <div id="list"></div>

<script>
const API = "http://localhost:4000";

async function load(){
  const res = await fetch(API + "/product");
  const data = await res.json();

  document.getElementById("list").innerHTML =
    data.map(p => `
      <div>
        <h3>${p.name}</h3>
        <p>$${p.price}</p>
        <button onclick="add('${p.id}')">加入购物车</button>
      </div>
    `).join("");
}

async function add(id){
  await fetch(API + "/cart/add", {
    method:"POST",
    headers:{ "Content-Type":"application/json" },
    body: JSON.stringify({ productId:id, qty:1 })
  });

  alert("已加入购物车");
}
</script>

</body>
</html>
EOF

echo "✅ SaaS赚钱系统生成完成"
echo ""
echo "运行："
echo "cd saas/server"
echo "npm install express cors dotenv jsonwebtoken axios stripe"
echo "node src/main.js"
echo ""
echo "打开：http://localhost:4000"