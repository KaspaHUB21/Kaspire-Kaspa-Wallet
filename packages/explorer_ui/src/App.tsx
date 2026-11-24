import {TransactionPage,LookupPage} from './chain';
import {BlockDagPage,BlockDetailPage} from './pages/BlockDagPage';
import {NftGallery,NftPage} from './NftGallery';
import { Navigate, Route, Routes, useParams, useNavigate } from "react-router-dom";
import {useEffect} from 'react';
import { ExplorerNav as HeaderNav } from "./ExplorerNav";
import { ExplorerPage } from "./pages/ExplorerPage";
import { FavoritesPage } from "./pages/FavoritesPage";
import { HomePage } from "./pages/HomePage";
import { Kcc20DetailPage } from "./pages/Kcc20DetailPage";
import { KnsPage } from "./pages/KnsPage";
import { DotkPage } from "./pages/DotkPage";
import { LabelsPage } from "./pages/LabelsPage";
import { NotFoundPage } from "./pages/NotFoundPage";
import { PrivacyPage } from "./pages/PrivacyPage";
import { TokenDetailPage } from "./pages/TokenDetailPage";
import { WalletKrc721CollectionPage } from "./pages/WalletKrc721CollectionPage";
import { WalletPage } from "./pages/WalletPage";

export default function App() {
  const navigate=useNavigate();
  useEffect(()=>{const onClick=(e:MouseEvent)=>{const a=(e.target as Element)?.closest('a');if(!a)return;const href=a.getAttribute('href')??'';
    if(href.startsWith('/')){e.preventDefault();e.stopPropagation();navigate(href);return;}
    if(href.startsWith('https://kaspanftnexus.com/')){const u=new URL(href);e.preventDefault();e.stopPropagation();navigate(u.pathname.replace(/^\/collection\//,'/collection/').replace(/^\/nft\//,'/nft/')+u.search);}
  };document.addEventListener('click',onClick,true);return()=>document.removeEventListener('click',onClick,true)},[navigate]);
  return (
    <div className="site-shell flex min-h-screen flex-col bg-kaspa-background text-kaspa-text">
      <div className="site-shell-header sticky top-0 z-50 border-b border-kaspa-border/80 bg-kaspa-background/92 backdrop-blur-xl">
        <HeaderNav />
      </div>
      <main className="site-shell-main mx-auto w-full max-w-7xl flex-1 px-4 pb-12 pt-6 sm:px-6 sm:pt-8 lg:px-8">
        <Routes>
          <Route path="/blockdag" element={<BlockDagPage/>}/><Route path="/block/:hash" element={<BlockDetailPage/>}/>
          <Route path="/" element={<HomePage />} /><Route path="/tx/:id" element={<TransactionPage/>}/><Route path="/lookup/:id" element={<LookupPage/>}/><Route path="/collection/:collectionId" element={<NftGallery/>}/><Route path="/nft/:collectionId/:tokenId" element={<NftPage/>}/>
          <Route path="/krc20" element={<ExplorerPage layer="KRC20" />} />
          <Route path="/krc721" element={<ExplorerPage layer="KRC721" />} />
          <Route path="/kcc20" element={<ExplorerPage layer="KCC20" />} />
          <Route path="/kcc20/:covenantId" element={<Kcc20DetailPage />} />
          <Route path="/l2/*" element={<Navigate to="/" replace />} />
          <Route path="/kns" element={<KnsPage />} />
          <Route path="/dotk" element={<DotkPage />} />
          <Route path="/dotk/:name" element={<DotkPage />} />
          <Route path="/combined" element={<Navigate to="/" replace />} />
          <Route path="/favorites" element={<FavoritesPage />} />
          <Route path="/labels" element={<LabelsPage />} />
          <Route path="/portfolio" element={<Navigate to="/" replace />} />
          <Route path="/privacy" element={<PrivacyPage />} />
          <Route path="/token/:id" element={<CanonicalTokenDetailRoute />} />
          <Route path="/wallet/krc20/:address/krc721/:ticker" element={<WalletKrc721CollectionPage />} />
          <Route path="/wallet/:network/:address" element={<ExplorerWalletRoute />} />
          <Route path="*" element={<NotFoundPage />} />
        </Routes>
      </main>
      <footer className="site-shell-footer border-t border-kaspa-border/70 px-4 py-8 text-center sm:px-6 lg:px-8">
        <div className="flex flex-col items-center gap-3">
          <a href="https://kaslab.space/" className="hub21-flow inline-flex text-sm font-bold" aria-label="Visit HUB21 at kaslab.space">
            Developed by HUB21
          </a>
          <a href="/privacy" className="text-xs font-semibold text-kaspa-muted transition hover:text-kaspa-primary">
            Privacy Policy
          </a>
        </div>
      </footer>
    </div>
  );
}

function CanonicalTokenDetailRoute() {
  const { id = "" } = useParams();
  if (/^(l2-|kasplex-|igra-|0x)/i.test(id)) return <Navigate to="/" replace />;
  const kcc20Match = /^kcc20-([a-f0-9]{64})$/i.exec(id);
  if (kcc20Match) {
    return <Navigate to={`/kcc20/${kcc20Match[1].toLowerCase()}`} replace />;
  }
  return <TokenDetailPage />;
}

function ExplorerWalletRoute(){
  const {network,address=''}=useParams();
  return network==='krc20'&&!/^0x/i.test(address)?<WalletPage/>:<Navigate to="/" replace/>;
}


