#!/bin/bash

set -e

echo "♻️  正在创建目录..."

mkdir -p saas/server/prisma
mkdir -p saas/server/src/middlewares
mkdir -p saas/server/src/routes
mkdir -p saas/server/src/utils
mkdir -p saas/app

# ------- server/.env -------
cat > saas/server/.env << EOF
DATABASE_URL=postgres://postgres:你的密码@localhost:5432/saas   # 必须改成你的数据库信息
JWT_SECRET=你自定义32位密钥
STRIPE_KEY=   # stripe预留
EOF

# ------- server/package.json -------
cat > saas/server/package.json << 'EOF'
{
  "name": "saas-server",
  "type": "module",
  "dependencies": {
    "@prisma/client": "^5.11.0",
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "dotenv": "^16.0.0",
    "express": "^4.18.0",
    "jsonwebtoken": "^9.0.0",
    "stripe": "^14.0.0"
  }
}
EOF

# ------- server/prisma/schema.prisma -------
cat > saas/server/prisma/schema.prisma << 'EOF'
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model Tenant {
  id        String   @id @default(cuid())
  name      String
  plan      String   @default("free")
  createdAt DateTime @default(now())
}

model User {
  id        String   @id @default(cuid())
  email     String   @unique
  password  String
  role      String   @default("owner")
  tenantId  String
}

model Product {
  id        String   @id @default(cuid())
  name      String
  sku       String   @unique
  price     Float
  stock     Int      @default(0)
  tenantId  String
  createdAt DateTime @default(now())
}

model StockLog {
  id        String   @id @default(cuid())
  productId String
  sku       String
  action    String   // in|out|verify
  quantity  Int
  operator  String?
  remark    String?
  createdAt DateTime @default(now())
  tenantId  String
}

model Order {
  id        String   @id @default(cuid())
  userId    String
  shopId    String
  productId String
  quantity  Int
  total     Float
  status    String   @default("pending")
  createdAt DateTime @default(now())
}

model Subscription {
  id        String   @id @default(cuid())
  tenantId  String
  status    String
  stripeId  String?
}
EOF

# ------- server/src/middlewares/auth.js -------
cat > saas/server/src/middlewares/auth.js << 'EOF'
import jwt from "jsonwebtoken";

export default function auth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader) return res.status(401).json({ error: "缺少token" });
  const token = authHeader.split(' ')[1];
  try {
    const data = jwt.verify(token, process.env.JWT_SECRET);
    req.user = data;
    next();
  } catch {
    res.status(403).json({ error: "token无效" });
  }
}
EOF

# ------- server/src/routes/auth.js -------
cat > saas/server/src/routes/auth.js << 'EOF'
import express from "express";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import { PrismaClient } from "@prisma/client";
const prisma = new PrismaClient();
const router = express.Router();

router.post("/register", async (req, res) => {
  try {
    const { email, password, tenantId } = req.body;
    if (!email || !password || !tenantId) return res.status(400).json({ error: "参数不足" });
    const exist = await prisma.user.findUnique({ where: { email } });
    if (exist) return res.status(400).json({ error: "邮箱已被注册" });

    const hash = await bcrypt.hash(password, 10);
    await prisma.user.create({
      data: { email, password: hash, tenantId }
    });
    res.json({ ok: true });
  } catch {
    res.status(500).json({ error: "注册失败" });
  }
});

router.post("/login", async (req, res) => {
  try {
    const { email, password } = req.body;
    const user = await prisma.user.findUnique({ where: { email } });
    if (!user) return res.status(400).json({ error: "未找到用户" });

    const ok = await bcrypt.compare(password, user.password);
    if (!ok) return res.status(400).json({ error: "密码错误" });

    const token = jwt.sign(
      { id: user.id, tenantId: user.tenantId },
      process.env.JWT_SECRET
    );
    res.json({ token });
  } catch {
    res.status(500).json({ error: "登录失败" });
  }
});

export default router;
EOF

# ------- server/src/routes/product.js -------
cat > saas/server/src/routes/product.js << 'EOF'
import express from "express";
import { PrismaClient } from "@prisma/client";
import auth from "../middlewares/auth.js";
const prisma = new PrismaClient();
const router = express.Router();

router.post("/", auth, async (req, res) => {
  try {
    const { name, sku, price } = req.body;
    if (!name || !sku || !price) return res.status(400).json({ error: "参数不足" });

    const product = await prisma.product.create({
      data: {
        name,
        sku,
        price: Number(price),
        tenantId: req.user.tenantId
      }
    });
    res.json(product);
  } catch {
    res.status(500).json({ error: "添加失败" });
  }
});

router.get("/", auth, async (req, res) => {
  try {
    const products = await prisma.product.findMany({
      where: { tenantId: req.user.tenantId }
    });
    res.json(products);
  } catch {
    res.status(500).json({ error: "查询失败" });
  }
});

export default router;
EOF

# ------- server/src/routes/order.js -------
cat > saas/server/src/routes/order.js << 'EOF'
import express from "express";
import { PrismaClient } from "@prisma/client";
import auth from "../middlewares/auth.js";
const prisma = new PrismaClient();
const router = express.Router();

router.post("/", auth, async (req, res) => {
  try {
    const { productId, quantity } = req.body;
    const product = await prisma.product.findUnique({ where: { id: productId } });
    if (!product) return res.status(404).json({ error: "无此商品" });
    if (product.stock < quantity) return res.status(400).json({ error: "库存不足" });

    await prisma.product.update({
      where: { id: productId },
      data: { stock: { decrement: Number(quantity) } }
    });

    const total = product.price * quantity;
    const order = await prisma.order.create({
      data: {
        userId: req.user.id,
        shopId: product.tenantId,
        productId,
        quantity: Number(quantity),
        total,
        status: "pending"
      }
    });
    res.json(order);
  } catch {
    res.status(500).json({ error: "下单失败" });
  }
});

export default router;
EOF

# ------- server/src/routes/stock.js -------
cat > saas/server/src/routes/stock.js << 'EOF'
import express from "express";
import { PrismaClient } from "@prisma/client";
import auth from "../middlewares/auth.js";
const prisma = new PrismaClient();
const router = express.Router();

router.post("/in", auth, async (req, res) => {
  const { sku, quantity = 1 } = req.body;
  const product = await prisma.product.findUnique({ where: { sku } });
  if (!product) return res.status(404).json({ error: "未找到SKU" });

  await prisma.product.update({
    where: { sku },
    data: { stock: { increment: Number(quantity) } }
  });
  await prisma.stockLog.create({
    data: {
      productId: product.id,
      sku,
      action: "in",
      quantity: Number(quantity),
      operator: req.user.id,
      tenantId: req.user.tenantId
    }
  });
  res.json({ ok: true, msg: "入库成功" });
});

router.post("/out", auth, async (req, res) => {
  const { sku, quantity = 1 } = req.body;
  const product = await prisma.product.findUnique({ where: { sku } });
  if (!product) return res.status(404).json({ error: "未找到SKU" });
  if (product.stock < quantity) return res.status(400).json({ error: "库存不足" });

  await prisma.product.update({
    where: { sku },
    data: { stock: { decrement: Number(quantity) } }
  });
  await prisma.stockLog.create({
    data: {
      productId: product.id,
      sku,
      action: "out",
      quantity: Number(quantity),
      operator: req.user.id,
      tenantId: req.user.tenantId
    }
  });
  res.json({ ok: true, msg: "出库成功" });
});

router.post("/verify", auth, async (req, res) => {
  const { sku } = req.body;
  const product = await prisma.product.findUnique({ where: { sku } });
  if (!product) return res.status(404).json({ error: "未找到SKU" });

  await prisma.product.update({
    where: { sku },
    data: { stock: 0 }
  });
  await prisma.stockLog.create({
    data: {
      productId: product.id,
      sku,
      action: "verify",
      quantity: 0,
      operator: req.user.id,
      tenantId: req.user.tenantId
    }
  });
  res.json({ ok: true, msg: "核销成功" });
});

export default router;
EOF

# ------- server/src/utils/stripe.js -------
cat > saas/server/src/utils/stripe.js << 'EOF'
import Stripe from "stripe";
const stripe = new Stripe(process.env.STRIPE_KEY);
export default stripe;
EOF

# ------- server/src/main.js -------
cat > saas/server/src/main.js << 'EOF'
import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import authRoutes from "./routes/auth.js";
import productRoutes from "./routes/product.js";
import orderRoutes from "./routes/order.js";
import stockRoutes from "./routes/stock.js";

dotenv.config();
const app = express();
app.use(cors());
app.use(express.json());

app.use("/auth", authRoutes);
app.use("/products", productRoutes);
app.use("/orders", orderRoutes);
app.use("/stock", stockRoutes);

app.listen(4000, () => {
  console.log("🚀 Server running at http://localhost:4000");
});
EOF

# --------------- app/package.json ---------------
cat > saas/app/package.json << 'EOF'
{
  "main": "node_modules/expo/AppEntry.js",
  "dependencies": {
    "axios": "^1.6.0",
    "expo": "~50.0.5",
    "expo-linear-gradient": "~12.7.0",
    "expo-barcode-scanner": "~12.5.0",
    "react": "18.2.0",
    "react-native": "0.73.4",
    "react-native-paper": "^5.10.0"
  }
}
EOF

# --------------- app/App.js ---------------
cat > saas/app/App.js << 'EOF'
import React, { useState } from 'react';
import { View, Text, TextInput, ScrollView, KeyboardAvoidingView, Platform, Button as Btn } from 'react-native';
import { Button, Card, Provider as PaperProvider } from 'react-native-paper';
import { LinearGradient } from 'expo-linear-gradient';
import axios from 'axios';
import Scan from './Scan';

const API = 'http://你的后端IP:4000'; // TODO

export default function App() {
  const [step, setStep] = useState('login');
  const [token, setToken] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [tenantId, setTenantId] = useState('');
  const [products, setProducts] = useState([]);
  const [name, setName] = useState('');
  const [sku, setSku] = useState('');
  const [price, setPrice] = useState('');

  async function login() {
    try {
      const res = await axios.post(\`\${API}/auth/login\`, { email, password });
      if (res.data.token) {
        setToken(res.data.token);
        setStep('product');
        load();
      } else { alert('登录失败'); }
    } catch { alert('登录异常，请检查网络或账户'); }
  }
  async function register() {
    try {
      const res = await axios.post(\`\${API}/auth/register\`, { email, password, tenantId });
      if (res.data.ok) { alert('注册成功'); setStep('login'); }
      else { alert('注册失败'); }
    } catch { alert('注册异常，请检查网络或账户'); }
  }
  async function load() {
    try {
      const res = await axios.get(\`\${API}/products\`, { headers: { Authorization: 'Bearer ' + token } });
      setProducts(res.data);
    } catch { setProducts([]); }
  }
  async function addProduct() {
    try {
      await axios.post(\`\${API}/products\`, { name, sku, price }, {
        headers: { Authorization: 'Bearer ' + token }
      });
      setName(""); setSku(""); setPrice("");
      load();
    } catch { alert('商品添加失败'); }
  }

  if (step === 'scan') return <Scan token={token} goBack={()=>setStep('product')} />
  return (
    <PaperProvider>
      <LinearGradient colors={['#141E30', '#243B55']} style={{ flex: 1 }}>
        <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : 'height'} style={{ flex: 1 }}>
          <ScrollView contentContainerStyle={{ flexGrow: 1, justifyContent: 'center', padding: 24 }}>
            <Text style={{
              fontSize: 36, fontWeight: 'bold', color: '#fff',
              textAlign: 'center', marginBottom: 32, letterSpacing: 2
            }}>🛒 SaaS 电商仓储</Text>
            {step === 'login' && (
              <Card style={{ marginBottom: 16, padding: 16, borderRadius: 18, backgroundColor: 'rgba(255,255,255,0.94)' }}>
                <Card.Title title="登录" />
                <TextInput placeholder="邮箱" value={email} onChangeText={setEmail} autoCapitalize="none"
                  style={{ marginBottom: 10, backgroundColor: '#F1F3F6', borderRadius: 8, padding: 12 }} />
                <TextInput placeholder="密码" value={password} secureTextEntry onChangeText={setPassword}
                  style={{ marginBottom: 10, backgroundColor: '#F1F3F6', borderRadius: 8, padding: 12 }} />
                <Button mode="contained" onPress={login}
                  style={{ marginBottom: 10, borderRadius: 10, backgroundColor: '#3a86ff' }}
                  labelStyle={{ color: '#fff' }}>登录</Button>
                <Button mode="text" onPress={() => setStep('register')} style={{ borderRadius: 10 }}>注册新账号</Button>
              </Card>
            )}
            {step === 'register' && (
              <Card style={{ marginBottom: 16, padding: 16, borderRadius: 18, backgroundColor: 'rgba(255,255,255,0.94)' }}>
                <Card.Title title="注册" />
                <TextInput placeholder="邮箱" value={email} onChangeText={setEmail} autoCapitalize="none"
                  style={{ marginBottom: 10, backgroundColor: '#F1F3F6', borderRadius: 8, padding: 12 }} />
                <TextInput placeholder="密码" value={password} secureTextEntry onChangeText={setPassword}
                  style={{ marginBottom: 10, backgroundColor: '#F1F3F6', borderRadius: 8, padding: 12 }} />
                <TextInput placeholder="租户ID" value={tenantId} onChangeText={setTenantId}
                  style={{ marginBottom: 15, backgroundColor: '#F1F3F6', borderRadius: 8, padding: 12 }} />
                <Button mode="contained" onPress={register}
                  style={{ marginBottom: 10, borderRadius: 10, backgroundColor: '#3a86ff' }}
                  labelStyle={{ color: '#fff' }}>注册</Button>
                <Button mode="text" onPress={() => setStep('login')} style={{ borderRadius: 10 }}>返回登录</Button>
              </Card>
            )}
            {step === 'product' && (
              <Card style={{ marginBottom: 16, padding: 16, borderRadius: 20, backgroundColor: 'rgba(255,255,255,0.97)' }}>
                <Card.Title title="商品管理" />
                <View style={{ marginBottom: 10 }}>
                  <TextInput placeholder="商品名" value={name} onChangeText={setName}
                    style={{ marginBottom: 6, backgroundColor: '#F1F3F6', borderRadius: 8, padding: 10 }} />
                  <TextInput placeholder="SKU" value={sku} onChangeText={setSku}
                    style={{ marginBottom: 6, backgroundColor: '#F1F3F6', borderRadius: 8, padding: 10 }} />
                  <TextInput placeholder="价格" value={price} onChangeText={setPrice}
                    style={{ marginBottom: 6, backgroundColor: '#F1F3F6', borderRadius: 8, padding: 10 }} keyboardType="numeric" />
                  <Button mode="contained" onPress={addProduct} style={{ borderRadius: 10, marginBottom: 8, backgroundColor: '#8338ec' }}> 添加 </Button>
                  <Btn title="扫码入/出库/核销" onPress={()=>setStep('scan')}/>
                </View>
                <View><Text style={{ fontWeight: "bold", color: "#38426A", marginBottom: 8 }}>商品列表：</Text>
                  {(products.length === 0) && <Text style={{ color: '#333' }}>暂无商品</Text>}
                  {products.map(p => (
                    <Card key={p.id} style={{
                      marginBottom: 8, backgroundColor: "#EEF2FB", borderRadius: 14,
                      shadowColor: "#ddd", shadowOffset: { width: 0, height: 4 }, shadowOpacity: 0.15,
                    }}>
                      <Card.Content style={{ flexDirection: "row", justifyContent: "space-between" }}>
                        <Text style={{ fontWeight: "500" }}>{p.name} (SKU:{p.sku}) 库存:{p.stock}</Text>
                        <Text style={{ color: '#2274A5' }}>¥{p.price}</Text>
                      </Card.Content>
                    </Card>
                  ))}
                </View>
                <Button mode="text" style={{ marginTop: 12, borderRadius: 10, backgroundColor: '#eee' }}
                  onPress={() => { setToken(''); setStep('login'); }}>
                  退出账号
                </Button>
              </Card>
            )}
            <Text style={{ textAlign: 'center', color: '#ddd', marginTop: 30, fontSize: 12 }}>© 2026 SaaS E-Commerce</Text>
          </ScrollView>
        </KeyboardAvoidingView>
      </LinearGradient>
    </PaperProvider>
  );
}
EOF

# --------------- app/Scan.js ---------------
cat > saas/app/Scan.js << 'EOF'
import React, { useState, useEffect } from 'react';
import { View, Text, Button, SafeAreaView } from 'react-native';
import { BarCodeScanner } from 'expo-barcode-scanner';
import axios from 'axios';

const API = 'http://你的后端IP:4000'; // TODO

export default function Scan({ token, goBack }) {
  const [hasPermission, setHasPermission] = useState(null);
  const [msg, setMsg] = useState("");
  const [scanned, setScanned] = useState(false);
  const [action, setAction] = useState("in");

  useEffect(() => {
    (async () => {
      const { status } = await BarCodeScanner.requestPermissionsAsync();
      setHasPermission(status === 'granted');
    })();
  }, []);

  const handleBarCodeScanned = ({ data }) => {
    setScanned(true);
    axios.post(\`\${API}/stock/\${action}\`, { sku: data }, {
      headers: { 'Authorization': 'Bearer ' + token }
    })
      .then(res => setMsg(res.data.msg || "操作成功"))
      .catch(e => setMsg(e.response?.data?.error || "接口异常"));
  };

  if (hasPermission === null) return <Text>请求相机权限中...</Text>;
  if (hasPermission === false) return <Text>无相机权限</Text>;

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: '#111' }}>
      <Text style={{ color: '#fff', fontSize: 20, textAlign: 'center', margin:16 }}>扫码{action === 'in' ? "入库" : action === 'out' ? "出库" : "核销"}</Text>
      <BarCodeScanner
        onBarCodeScanned={scanned ? undefined : handleBarCodeScanned}
        style={{ flex: 1 }}
      />
      <View style={{ margin: 16 }}>
        {!!msg && <Text style={{ color: 'yellow', textAlign: 'center' }}>{msg}</Text>}
        {scanned && <Button title={'再扫一次'} onPress={() => { setScanned(false); setMsg(""); }} />}
        <View style={{ flexDirection: 'row', justifyContent: 'space-around', marginTop: 16 }}>
          <Button title="入库" onPress={()=>setAction('in')} color={action==='in'?'green':'gray'}/>
          <Button title="出库" onPress={()=>setAction('out')} color={action==='out'?'orange':'gray'}/>
          <Button title="核销" onPress={()=>setAction('verify')} color={action==='verify'?'red':'gray'}/>
          <Button title="返回" onPress={goBack} />
        </View>
      </View>
    </SafeAreaView>
  )
}
EOF

echo "✅ 初始化完成，路径在 saas/"
echo "👉 进入 server，执行："
echo "cd saas/server"
echo "npm install"
echo "npx prisma migrate dev --name allinit"
echo "node src/main.js"
echo ""
echo "👉 进入 app，执行（Expo需已全局安装 npx expo）："
echo "cd ../app"
echo "npm install"
echo "npx expo start"
echo ""
echo "🎉 一体化项目已准备好！"