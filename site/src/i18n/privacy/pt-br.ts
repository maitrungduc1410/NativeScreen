export default {
  title: "Política de Privacidade · Native Screen",
  desc: "O que o Native Screen faz com suas gravações e seus dados: tudo fica no seu computador, sem conta, sem análises e sem envios.",
  back: "Voltar ao início",
  updated: "Última atualização: {date}",
  h1: "Política de Privacidade",
  note: "Esta tradução é apenas informativa. Se houver diferença em relação à <a href=\"/privacy/\">versão em inglês</a>, prevalece a versão em inglês.",
  lede: "O Native Screen grava e edita no seu computador. Não há conta, nenhum servidor nosso, nenhuma análise e nenhum anúncio. O app nunca envia suas gravações.",
  scope: "Esta política vale para os apps Native Screen para macOS e Windows (incluindo as versões da Microsoft Store e da Mac App Store) e para este site. O app é gratuito e de código aberto, então tudo o que está abaixo pode ser conferido no <a href=\"{repo}\">código-fonte</a>.",

  stayH: "O que fica no seu computador",
  stayP: "Tudo o que você cria com o Native Screen é guardado no seu computador e nunca é enviado a lugar nenhum pelo app:",
  stayList: [
    "gravações de tela, janela e área, vídeo da câmera, áudio do microfone e do sistema;",
    "as posições do mouse, os cliques e as teclas registrados em cada gravação, usados para os zooms automáticos, o cursor suave e a exibição de atalhos de teclado, e o nome da janela ou do app gravado;",
    "desenhos feitos na tela durante a gravação, notas do apresentador e perfis de gravação;",
    "projetos, edições, predefinições, legendas e transcrições;",
    "vídeos, GIFs, imagens e arquivos de legenda exportados;",
    "seus ajustes.",
  ],
  onDevice: "Legendas, transcrições, detecção de dados sensíveis (e-mails, chaves, rostos), rastreamento facial e remoção do fundo da câmera rodam no seu computador. No macOS, eles usam os frameworks integrados da Apple, e o reconhecimento de fala é configurado para rodar só no dispositivo, então nenhum áudio é enviado à Apple. No Windows, as legendas usam um modelo Whisper e a remoção do fundo usa um modelo MODNet. Cada um é baixado uma vez e depois roda localmente.",
  keys: "As teclas só são registradas enquanto uma gravação está em andamento. Elas são salvas dentro daquele projeto e em nenhum outro lugar, e você pode apagá-las apagando o projeto.",

  permH: "Permissões que o app pede",
  permP: "Cada permissão é usada só para o recurso indicado ao lado.",
  permCols: ["Permissão", "Para quê"],
  perms: [
    ["Gravação de tela", "Para gravar uma tela, uma janela ou uma área que você escolher."],
    ["Microfone", "Para gravar sua voz e narrações, quando você liga o microfone."],
    ["Câmera", "Para gravar sua câmera, quando você a liga."],
    ["Acessibilidade (macOS, download direto)", "Para listar e selecionar janelas, e para acompanhar cliques e teclas durante uma gravação."],
    ["Monitoramento de Entrada (versão da Mac App Store)", "Só durante uma gravação: as teclas pressionadas viram atalhos sobrepostos. Esta versão pede essa permissão no lugar de Acessibilidade."],
    ["Reconhecimento de fala (macOS)", "Para criar legendas com o reconhecedor da Apple no dispositivo."],
    ["Entrada de teclado e mouse (Windows)", "Só durante uma gravação: os cliques geram zooms automáticos e efeitos de clique, e as teclas viram a exibição de atalhos."],
    ["Confiança total (Windows)", "O Native Screen é um app de desktop. Ele precisa de acesso total para usar a captura de tela, a captura do áudio do sistema, a codificação de vídeo por hardware e a GPU do Windows, que apps empacotados não conseguem acessar de outra forma."],
    ["Internet", "Só para os downloads e as verificações de atualização listados abaixo."],
  ],

  leaveH: "O que sai do seu computador",
  leaveP: "O app só se conecta à internet nestes casos. Nenhum deles inclui suas gravações, seus projetos ou qualquer coisa que você digitou.",
  leaveCols: ["Quando", "Para onde", "O que é enviado"],
  leave: [
    ["Na primeira vez que você usa legendas ou a remoção do fundo da câmera no Windows", "Hugging Face (huggingface.co)", "Uma solicitação para baixar o arquivo do modelo. O Hugging Face vê seu endereço IP, como em qualquer download. O app para macOS não baixa nenhum modelo."],
    ["Ao verificar e baixar atualizações (macOS fora da Mac App Store, e Windows fora da Microsoft Store)", "GitHub", "Uma solicitação da versão mais recente e, quando houver, do arquivo de atualização. O GitHub vê seu endereço IP e os cabeçalhos comuns da solicitação. Nada sobre você ou suas gravações é incluído. Você pode desligar a verificação automática nos Ajustes."],
    ["Versão da Microsoft Store", "Microsoft", "A Store instala e atualiza o app, que não tem atualizador próprio. A Microsoft pode coletar dados de diagnóstico de acordo com a sua própria <a href=\"https://privacy.microsoft.com/privacystatement\">declaração de privacidade</a>."],
    ["Versão da Mac App Store", "Apple", "A App Store instala e atualiza o app, que não tem atualizador próprio e não se conecta à internet. A Apple pode coletar dados de diagnóstico de acordo com a sua própria <a href=\"https://www.apple.com/legal/privacy/\">política de privacidade</a>."],
  ],

  agentsH: "Agentes de IA",
  agentsP: "Se você ligar <strong>Ajustes &gt; Agentes de IA</strong> (desligado por padrão), agentes de IA como Claude, Codex ou Cursor podem controlar o Native Screen por uma conexão local que só programas rodando na sua conta de usuário neste computador conseguem abrir. Um agente pode fazer o que você faz no app: iniciar uma gravação (a barra de gravação e a contagem regressiva sempre aparecem), abrir e editar projetos, ler os dados e quadros dos projetos, exportar vídeos e imagens para arquivos e entregar ao app um arquivo de vídeo ou imagem do seu computador para importar. O app não envia nada pela internet para isso, mas o agente pode enviar o que lê ao provedor de IA dele, conforme os termos desse provedor. Desligue o ajuste para encerrar todo acesso de agentes. A versão da Mac App Store não inclui este recurso.",

  notH: "O que não fazemos",
  notList: [
    "Sem conta e sem login.",
    "Sem análises, rastreamento de uso ou publicidade.",
    "O app não envia relatórios de falhas.",
    "Não vendemos nem compartilhamos dados pessoais. Não temos nenhum para compartilhar.",
  ],

  webH: "Este site",
  webP: "nativescreen.app é um site estático hospedado no GitHub Pages. Ele não tem análises e não grava cookies. As fontes são carregadas do Google Fonts, então o GitHub e o Google recebem seu endereço IP e dados do navegador ao servir a página. Suas escolhas de tema e idioma ficam no armazenamento local do navegador e nunca saem do seu dispositivo.",

  kidsH: "Crianças",
  kidsP: "O Native Screen não coleta informações pessoais de ninguém, incluindo crianças com menos de 13 anos.",

  choiceH: "Suas escolhas",
  choiceP: "Seus dados estão no seu computador, então você tem o controle. Apague um projeto para remover suas gravações e dados de entrada. Desinstalar remove o app. Projetos, exportações e modelos baixados continuam no seu computador até você apagá-los.",

  changesH: "Alterações",
  changesP: "Se esta política mudar, a nova versão será publicada nesta página com uma nova data. O histórico de cada alteração é público no <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">repositório</a>.",

  contactH: "Contato",
  contactP: "Dúvidas sobre privacidade: envie um e-mail para <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a> ou abra uma issue no <a href=\"{repo}/issues\">GitHub</a>.",
};
