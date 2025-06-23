<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>个人自用数据备份脚本 - 交互式指南</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <!-- Chosen Palette: Soothing Sage (Background: #f0fdf4, Text: #14532d, Accent: #22c55e) -->
    <!-- Application Structure Plan: A single-page application with a fixed top navigation bar (主页, 安装指南, 使用说明, 常见问题) to switch between content sections. This task-oriented structure is more user-friendly than a linear README, allowing users to jump directly to installation steps, usage guides, or troubleshooting. Interactions include 'copy to clipboard' buttons for commands and accordions for FAQs and usage details, enhancing usability for novice users. -->
    <!-- Visualization & Content Choices: Goal: Present instructional text interactively. Method: No charts are needed. Feature cards (HTML/CSS) for the homepage to inform. A step-by-step layout for the installation guide (Goal: Organize) with copy-to-clipboard buttons (Interaction). Custom accordions for the Usage Guide and FAQ sections (Goal: Organize & Inform) to reduce cognitive load. All visuals are built with Tailwind CSS, confirming NO SVG/Mermaid. -->
    <!-- CONFIRMATION: NO SVG graphics used. NO Mermaid JS used. -->
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Noto+Sans+SC:wght@400;500;700&display=swap');
        body {
            font-family: 'Noto Sans SC', sans-serif;
            background-color: #f0fdf4;
            color: #14532d;
        }
        .nav-link {
            transition: all 0.3s ease;
            position: relative;
        }
        .nav-link:after {
            content: '';
            position: absolute;
            width: 0;
            height: 2px;
            bottom: -4px;
            left: 50%;
            transform: translateX(-50%);
            background-color: #22c55e;
            transition: width 0.3s ease;
        }
        .nav-link.active, .nav-link:hover {
            color: #22c55e;
        }
        .nav-link.active:after, .nav-link:hover:after {
            width: 100%;
        }
        .content-section {
            display: none;
        }
        .content-section.active {
            display: block;
        }
        .accordion-content {
            max-height: 0;
            overflow: hidden;
            transition: max-height 0.5s ease-in-out, padding 0.5s ease-in-out;
        }
        .accordion-button.open + .accordion-content {
            padding-top: 1rem;
            padding-bottom: 1rem;
        }
        .code-block {
            position: relative;
        }
        .copy-button {
            position: absolute;
            top: 0.5rem;
            right: 0.5rem;
            background-color: #166534;
            color: #dcfce7;
            padding: 0.25rem 0.5rem;
            border-radius: 0.375rem;
            font-size: 0.75rem;
            cursor: pointer;
            transition: background-color 0.2s ease;
        }
        .copy-button:hover {
            background-color: #15803d;
        }
        .copy-button.copied {
            background-color: #22c55e;
            color: white;
        }
    </style>
</head>
<body class="antialiased">

    <header class="bg-white/80 backdrop-blur-md shadow-sm sticky top-0 z-50">
        <nav class="container mx-auto px-6 py-4">
            <ul class="flex justify-center space-x-6 md:space-x-10 text-base md:text-lg font-medium text-green-800">
                <li><a href="#home" class="nav-link active">主页</a></li>
                <li><a href="#install" class="nav-link">安装指南</a></li>
                <li><a href="#usage" class="nav-link">使用说明</a></li>
                <li><a href="#faq" class="nav-link">常见问题</a></li>
            </ul>
        </nav>
    </header>

    <main class="container mx-auto px-6 py-8 md:py-16">
        
        <!-- 主页 Section -->
        <section id="home" class="content-section active">
            <div class="text-center mb-12">
                <h1 class="text-4xl md:text-5xl font-bold text-green-900 mb-4">个人自用数据备份脚本</h1>
                <p class="text-lg md:text-xl text-green-700 max-w-3xl mx-auto">一个强大的 Bash 脚本，用于自动化和手动备份数据到云存储，提供友好的命令行菜单，让数据备份变得简单可靠。</p>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <div class="flex items-center mb-4">
                        <span class="text-3xl mr-4">⏱️</span>
                        <h3 class="text-xl font-bold text-green-900">智能自动备份</h3>
                    </div>
                    <p class="text-green-800">只需设置一次备份间隔天数，配合 Cron Job，脚本即可智能判断并自动执行备份，无需手动干预。</p>
                </div>
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <div class="flex items-center mb-4">
                        <span class="text-3xl mr-4">🚀</span>
                        <h3 class="text-xl font-bold text-green-900">一键手动备份</h3>
                    </div>
                    <p class="text-green-800">需要立即备份？通过菜单选择“手动备份”，即可随时触发一次完整的备份上传流程。</p>
                </div>
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <div class="flex items-center mb-4">
                        <span class="text-3xl mr-4">☁️</span>
                        <h3 class="text-xl font-bold text-green-900">多云存储支持</h3>
                    </div>
                    <p class="text-green-800">全面支持 S3 兼容存储（如 Cloudflare R2）和通用的 WebDAV 协议，让您的数据备份更灵活。</p>
                </div>
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <div class="flex items-center mb-4">
                        <span class="text-3xl mr-4">⚙️</span>
                        <h3 class="text-xl font-bold text-green-900">高度可配置</h3>
                    </div>
                    <p class="text-green-800">无论是备份路径、备份频率还是云存储目标，一切尽在掌握。通过简单的菜单交互即可完成所有配置。</p>
                </div>
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <div class="flex items-center mb-4">
                        <span class="text-3xl mr-4">🖥️</span>
                        <h3 class="text-xl font-bold text-green-900">友好的命令行界面</h3>
                    </div>
                    <p class="text-green-800">清晰的菜单结构和详细的提示信息，即使是命令行新手也能轻松上手，告别复杂命令。</p>
                </div>
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <div class="flex items-center mb-4">
                        <span class="text-3xl mr-4">📝</span>
                        <h3 class="text-xl font-bold text-green-900">详细的日志记录</h3>
                    </div>
                    <p class="text-green-800">每一次备份操作，无论是成功还是失败，都会被详细记录到日志文件中，方便追溯和排查问题。</p>
                </div>
            </div>
        </section>

        <!-- 安装指南 Section -->
        <section id="install" class="content-section">
            <div class="text-center mb-12">
                <h2 class="text-3xl md:text-4xl font-bold text-green-900 mb-3">安装指南</h2>
                <p class="text-lg text-green-700">按照以下五个步骤，轻松完成脚本的安装与设置。</p>
            </div>
            <div class="max-w-4xl mx-auto space-y-6">
                <!-- Step 1 -->
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <h3 class="text-xl font-bold text-green-900 mb-3">第一步：保存脚本文件</h3>
                    <p class="text-green-800 mb-4">使用 `nano` 编辑器创建一个名为 `personal_backup.sh` 的文件，并将脚本代码粘贴进去。</p>
                    <div class="code-block bg-green-900 text-green-100 rounded-lg p-4 font-mono text-sm">
                        <button class="copy-button" data-clipboard-text="nano ~/personal_backup.sh">复制</button>
                        <p>nano ~/personal_backup.sh</p>
                    </div>
                </div>
                <!-- Step 2 -->
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <h3 class="text-xl font-bold text-green-900 mb-3">第二步：给予脚本执行权限</h3>
                    <p class="text-green-800 mb-4">执行以下命令，使脚本文件变为可执行状态。</p>
                    <div class="code-block bg-green-900 text-green-100 rounded-lg p-4 font-mono text-sm">
                        <button class="copy-button" data-clipboard-text="chmod +x ~/personal_backup.sh">复制</button>
                        <p>chmod +x ~/personal_backup.sh</p>
                    </div>
                </div>
                <!-- Step 3 -->
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <h3 class="text-xl font-bold text-green-900 mb-3">第三步：设置快捷启动 (可选)</h3>
                    <p class="text-green-800 mb-4">为了方便使用，可以为脚本创建一个别名 `bf`。编辑您的 `~/.bashrc` 或 `~/.zshrc` 文件，在末尾添加以下行。</p>
                    <div class="code-block bg-green-900 text-green-100 rounded-lg p-4 font-mono text-sm">
                        <button class="copy-button" data-clipboard-text="alias bf='bash ~/personal_backup.sh'">复制</button>
                        <p>alias bf='bash ~/personal_backup.sh'</p>
                    </div>
                     <p class="text-green-800 mt-4">别忘了执行 `source ~/.bashrc` 或 `source ~/.zshrc` 使其生效。</p>
                </div>
                <!-- Step 4 -->
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <h3 class="text-xl font-bold text-green-900 mb-3">第四步：安装脚本依赖</h3>
                    <p class="text-green-800 mb-4">脚本需要 `zip`, `awscli`, `curl` 等工具。根据您的操作系统运行相应命令进行安装。</p>
                    <p class="font-semibold text-green-800 mb-2">Debian/Ubuntu 系统:</p>
                    <div class="code-block bg-green-900 text-green-100 rounded-lg p-4 font-mono text-sm mb-4">
                        <button class="copy-button" data-clipboard-text="sudo apt update && sudo apt install zip awscli curl -y">复制</button>
                        <p>sudo apt update && sudo apt install zip awscli curl -y</p>
                    </div>
                    <p class="font-semibold text-green-800 mb-2">CentOS/RHEL 系统:</p>
                    <div class="code-block bg-green-900 text-green-100 rounded-lg p-4 font-mono text-sm">
                        <button class="copy-button" data-clipboard-text="sudo yum install zip awscli curl -y">复制</button>
                        <p>sudo yum install zip awscli curl -y</p>
                    </div>
                </div>
                <!-- Step 5 -->
                <div class="bg-white p-6 rounded-xl shadow-lg border border-green-200/50">
                    <h3 class="text-xl font-bold text-green-900 mb-3">第五步：设置 Cron Job (实现自动备份)</h3>
                    <p class="text-green-800 mb-4">执行 `crontab -e`，添加以下任务，让脚本每天自动检查是否需要备份。**请务必将路径修改为您的实际路径。**</p>
                    <div class="code-block bg-green-900 text-green-100 rounded-lg p-4 font-mono text-sm">
                        <button class="copy-button" data-clipboard-text="0 0 * * * bash /root/personal_backup.sh check_auto_backup > /dev/null 2>&1">复制</button>
                        <p>0 0 * * * bash /root/personal_backup.sh check_auto_backup > /dev/null 2>&1</p>
                    </div>
                </div>
            </div>
        </section>

        <!-- 使用说明 Section -->
        <section id="usage" class="content-section">
            <div class="text-center mb-12">
                <h2 class="text-3xl md:text-4xl font-bold text-green-900 mb-3">使用说明</h2>
                <p class="text-lg text-green-700">了解脚本菜单中每一个选项的功能和用法。</p>
            </div>
            <div class="max-w-4xl mx-auto space-y-4">
                <div class="bg-white rounded-xl shadow-lg border border-green-200/50 overflow-hidden">
                    <button class="accordion-button w-full text-left p-6 flex justify-between items-center hover:bg-green-50/50 transition-colors">
                        <span class="text-lg font-semibold text-green-900">1. 自动备份设定</span>
                        <span class="text-2xl text-green-500 transform transition-transform duration-500">&#x2795;</span>
                    </button>
                    <div class="accordion-content px-6 text-green-800">
                        <p>设置自动备份的间隔天数。脚本会配合 Cron Job，根据此间隔智能判断是否执行备份，无需频繁修改 Cron 任务。</p>
                    </div>
                </div>
                <div class="bg-white rounded-xl shadow-lg border border-green-200/50 overflow-hidden">
                    <button class="accordion-button w-full text-left p-6 flex justify-between items-center hover:bg-green-50/50 transition-colors">
                        <span class="text-lg font-semibold text-green-900">2. 手动备份</span>
                        <span class="text-2xl text-green-500 transform transition-transform duration-500">&#x2795;</span>
                    </button>
                    <div class="accordion-content px-6 text-green-800">
                        <p>随时触发一次立即备份上传操作，并将备份过程和结果实时展示在终端。</p>
                    </div>
                </div>
                 <div class="bg-white rounded-xl shadow-lg border border-green-200/50 overflow-hidden">
                    <button class="accordion-button w-full text-left p-6 flex justify-between items-center hover:bg-green-50/50 transition-colors">
                        <span class="text-lg font-semibold text-green-900">3. 自定义备份路径</span>
                        <span class="text-2xl text-green-500 transform transition-transform duration-500">&#x2795;</span>
                    </button>
                    <div class="accordion-content px-6 text-green-800">
                        <p>指定要备份的文件或文件夹的绝对路径。例如：`/home/user/my_documents`。</p>
                    </div>
                </div>
                <div class="bg-white rounded-xl shadow-lg border border-green-200/50 overflow-hidden">
                    <button class="accordion-button w-full text-left p-6 flex justify-between items-center hover:bg-green-50/50 transition-colors">
                        <span class="text-lg font-semibold text-green-900">5. 云存储设定</span>
                        <span class="text-2xl text-green-500 transform transition-transform duration-500">&#x2795;</span>
                    </button>
                    <div class="accordion-content px-6 text-green-800 space-y-2">
                        <p>进入子菜单配置 S3/R2 和 WebDAV 存储。出于安全考虑，这些凭证不会被保存，每次启动脚本时需要重新输入，或通过 `aws configure` 等标准方式进行配置。</p>
                        <p><strong>Cloudflare R2 Endpoint 示例:</strong> `https://&lt;ACCOUNT_ID&gt;.r2.cloudflarestorage.com`</p>
                    </div>
                </div>
                <div class="bg-white rounded-xl shadow-lg border border-green-200/50 overflow-hidden">
                    <button class="accordion-button w-full text-left p-6 flex justify-between items-center hover:bg-green-50/50 transition-colors">
                        <span class="text-lg font-semibold text-green-900">999. 卸载脚本</span>
                        <span class="text-2xl text-green-500 transform transition-transform duration-500">&#x2795;</span>
                    </button>
                    <div class="accordion-content px-6 text-green-800">
                        <p>此选项会删除脚本自身、配置文件(`~/.personal_backup_config`)和日志文件(`~/.personal_backup_log.txt`)。请注意，手动设置的别名 `bf` 需要您自行删除。</p>
                    </div>
                </div>
            </div>
        </section>

        <!-- 常见问题 Section -->
        <section id="faq" class="content-section">
            <div class="text-center mb-12">
                <h2 class="text-3xl md:text-4xl font-bold text-green-900 mb-3">常见问题与故障排除</h2>
                <p class="text-lg text-green-700">遇到问题了？在这里查找解决方案。</p>
            </div>
             <div class="max-w-4xl mx-auto space-y-4">
                <div class="bg-white rounded-xl shadow-lg border border-green-200/50 overflow-hidden">
                    <button class="accordion-button w-full text-left p-6 flex justify-between items-center hover:bg-green-50/50 transition-colors">
                        <span class="text-lg font-semibold text-green-900">问题：运行脚本时提示 `command not found` 或 `syntax error`</span>
                        <span class="text-2xl text-green-500 transform transition-transform duration-500">&#x2795;</span>
                    </button>
                    <div class="accordion-content px-6 text-green-800">
                        <p><strong>原因:</strong> 这通常是由于复制粘贴代码时引入了不可见的特殊字符，或者文件编码/换行符格式不正确（例如在 Windows 编辑后上传到 Linux）。</p>
                        <p class="mt-2"><strong>解决方案:</strong></p>
                        <ul class="list-disc list-inside mt-1 space-y-1">
                            <li>最彻底的方法是重新从 GitHub 仓库复制最新的脚本代码。</li>
                            <li>使用 `nano` 等 Linux 内置编辑器进行操作，避免跨系统编辑。</li>
                            <li>可以尝试运行 `dos2unix ~/personal_backup.sh` 命令来修复换行符问题。</li>
                        </ul>
                    </div>
                </div>
                <div class="bg-white rounded-xl shadow-lg border border-green-200/50 overflow-hidden">
                    <button class="accordion-button w-full text-left p-6 flex justify-between items-center hover:bg-green-50/50 transition-colors">
                        <span class="text-lg font-semibold text-green-900">问题：提示 “检测到以下依赖项缺失...”</span>
                        <span class="text-2xl text-green-500 transform transition-transform duration-500">&#x2795;</span>
                    </button>
                    <div class="accordion-content px-6 text-green-800">
                        <p><strong>原因:</strong> 您的系统缺少脚本运行所需的工具，如 `zip`, `awscli`, `curl`。</p>
                        <p class="mt-2"><strong>解决方案:</strong> 请参照“安装指南”第四步，根据您的操作系统运行相应的命令来安装这些缺失的依赖项。</p>
                    </div>
                </div>
                 <div class="bg-white rounded-xl shadow-lg border border-green-200/50 overflow-hidden">
                    <button class="accordion-button w-full text-left p-6 flex justify-between items-center hover:bg-green-50/50 transition-colors">
                        <span class="text-lg font-semibold text-green-900">问题：S3/R2 或 WebDAV 上传失败</span>
                        <span class="text-2xl text-green-500 transform transition-transform duration-500">&#x2795;</span>
                    </button>
                    <div class="accordion-content px-6 text-green-800">
                        <p><strong>原因:</strong> 大部分情况是凭证或配置信息错误。</p>
                         <p class="mt-2"><strong>解决方案:</strong></p>
                        <ul class="list-disc list-inside mt-1 space-y-1">
                            <li>仔细检查您在“云存储设定”中输入的 Access Key, Secret Key, Endpoint URL, Bucket Name 等信息是否完全正确。</li>
                            <li>对于 R2，请确保 Endpoint URL 中的 `&lt;ACCOUNT_ID&gt;` 已被正确替换。</li>
                            <li>检查您的网络连接是否正常，以及服务器防火墙是否允许访问云存储服务。</li>
                            <li>对于 S3/R2，推荐使用 `aws configure` 命令配置持久性凭证，这更稳定且安全。</li>
                        </ul>
                    </div>
                </div>
            </div>
        </section>

    </main>
    
    <footer class="text-center py-8 mt-12 border-t border-green-200">
        <p class="text-green-700">由个人自用数据备份脚本提供支持 | <a href="#" id="github-link" class="text-green-600 hover:text-green-800 font-semibold">查看 GitHub 仓库</a></p>
    </footer>

    <script>
        document.addEventListener('DOMContentLoaded', function () {
            const navLinks = document.querySelectorAll('.nav-link');
            const sections = document.querySelectorAll('.content-section');

            // Navigation handler
            function setActiveSection(hash) {
                const targetHash = hash || '#home';
                
                navLinks.forEach(link => {
                    link.classList.toggle('active', link.hash === targetHash);
                });

                sections.forEach(section => {
                    section.classList.toggle('active', '#' + section.id === targetHash);
                });
            }

            navLinks.forEach(link => {
                link.addEventListener('click', function (e) {
                    e.preventDefault();
                    const targetHash = this.hash;
                    window.history.pushState(null, null, targetHash);
                    setActiveSection(targetHash);
                    window.scrollTo(0, 0);
                });
            });
            
            // Set initial section based on URL hash
            setActiveSection(window.location.hash);


            // Accordion handler
            document.querySelectorAll('.accordion-button').forEach(button => {
                button.addEventListener('click', () => {
                    const content = button.nextElementSibling;
                    const icon = button.querySelector('span:last-child');

                    button.classList.toggle('open');
                    
                    if (button.classList.contains('open')) {
                        content.style.maxHeight = content.scrollHeight + "px";
                        icon.style.transform = 'rotate(45deg)';
                    } else {
                        content.style.maxHeight = '0';
                        icon.style.transform = 'rotate(0deg)';
                    }
                });
            });

            // Copy to clipboard handler
            document.querySelectorAll('.copy-button').forEach(button => {
                button.addEventListener('click', () => {
                    const textToCopy = button.dataset.clipboardText;
                    
                    // A fallback for navigator.clipboard for cross-origin iframes
                    const textArea = document.createElement('textarea');
                    textArea.value = textToCopy;
                    document.body.appendChild(textArea);
                    textArea.select();
                    try {
                        document.execCommand('copy');
                        button.textContent = '已复制!';
                        button.classList.add('copied');
                        setTimeout(() => {
                            button.textContent = '复制';
                            button.classList.remove('copied');
                        }, 2000);
                    } catch (err) {
                        console.error('Fallback: Oops, unable to copy', err);
                    }
                    document.body.removeChild(textArea);
                });
            });
            
            // Dummy Github link
             document.getElementById('github-link').addEventListener('click', function(e) {
                e.preventDefault();
                alert('请将此处的链接替换为您真实的 GitHub 仓库地址！');
            });
        });
    </script>
</body>
</html>
