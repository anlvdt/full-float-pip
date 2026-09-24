// catalog.js — Controller for VibeWatch Cinema dashboard
// 100% Zero Emojis, Clean UI/UX, Multi-Section Home Rails, Instant Live Search & Native Float Window

let currentSource = 'all';
let currentCategory = 'moi';
let currentGenre = '';
let currentCountry = '';
let currentAudioFilter = 'all';
let currentViewMode = 'view-poster'; // 'view-poster' or 'view-cinema'
let currentPage = 1;
let currentSearchKeyword = '';
let currentMovie = null;
let currentSpotlightMovie = null;

const FALLBACK_POSTER = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='240' height='360' viewBox='0 0 240 360'><rect width='240' height='360' fill='%2316161f'/><circle cx='120' cy='160' r='32' fill='%23222230'/><polygon points='114,146 134,160 114,174' fill='%23ffffff'/><text x='50%25' y='216' dominant-baseline='middle' text-anchor='middle' fill='%23888899' font-family='sans-serif' font-weight='600' font-size='13'>VibeWatch Cinema</text></svg>";

const PLAY_ICON_SVG = `<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><polygon points="6,4 20,12 6,20"/></svg>`;

document.addEventListener('DOMContentLoaded', () => {
    if (typeof MovieImages !== 'undefined') MovieImages.install(document);
    initUI();
    loadContinueWatching();
    navigateView();
});

// MARK: - Navigation View Router
function navigateView() {
    const homeView = document.getElementById('home-view');
    const gridView = document.getElementById('grid-view');
    const heroSpotlight = document.getElementById('hero-spotlight');

    if (currentSearchKeyword) {
        // Search View
        homeView?.classList.add('hidden');
        gridView?.classList.remove('hidden');
        heroSpotlight?.classList.add('hidden');
        searchMovies(currentSearchKeyword);
    } else if (currentCategory === 'moi' && !currentGenre && !currentCountry) {
        // Home View with Multi-Sections
        homeView?.classList.remove('hidden');
        gridView?.classList.add('hidden');
        heroSpotlight?.classList.remove('hidden');
        loadHomePage();
    } else {
        // Specific Category / Filter / Favorites View
        homeView?.classList.add('hidden');
        gridView?.classList.remove('hidden');
        heroSpotlight?.classList.add('hidden');

        if (currentCategory === 'favorites') {
            loadFavorites();
        } else {
            loadMovies();
        }
    }
}

// MARK: - UI Initialization
function initUI() {
    const searchInput = document.getElementById('search-input');
    const searchClear = document.getElementById('search-clear');
    const searchDropdown = document.getElementById('search-suggestions');
    let debounceTimer = null;
    let suggestTimer = null;

    // Search Input with Instant Live Autocomplete Suggestions
    searchInput?.addEventListener('input', (e) => {
        const val = e.target.value.trim();
        if (val) {
            searchClear?.classList.remove('hidden');
        } else {
            searchClear?.classList.add('hidden');
            searchDropdown?.classList.add('hidden');
        }

        // Live autocomplete suggest
        clearTimeout(suggestTimer);
        if (val.length >= 2) {
            suggestTimer = setTimeout(async () => {
                const suggestions = await MovieService.quickSuggest(val, currentSource, 6);
                renderSearchSuggestions(suggestions, val);
            }, 220);
        } else {
            searchDropdown?.classList.add('hidden');
        }

        // Debounced full search if user pauses
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => {
            if (val) {
                currentSearchKeyword = val;
                currentPage = 1;
                navigateView();
            }
        }, 600);
    });

    searchInput?.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            searchDropdown?.classList.add('hidden');
            const val = searchInput.value.trim();
            if (val) {
                currentSearchKeyword = val;
                currentPage = 1;
                navigateView();
            }
        } else if (e.key === 'Escape') {
            searchDropdown?.classList.add('hidden');
        }
    });

    // Close suggestions dropdown when clicking outside
    document.addEventListener('click', (e) => {
        if (!e.target.closest('.search-box')) {
            searchDropdown?.classList.add('hidden');
        }
    });

    searchClear?.addEventListener('click', () => {
        if (searchInput) searchInput.value = '';
        searchClear.classList.add('hidden');
        searchDropdown?.classList.add('hidden');
        currentSearchKeyword = '';
        currentPage = 1;
        navigateView();
    });

    // Source Selector
    const sourceSelect = document.getElementById('source-select');
    sourceSelect?.addEventListener('change', (e) => {
        currentSource = e.target.value;
        currentPage = 1;
        navigateView();
    });

    // Ghost Mode Toggle — sync real native state
    const ghostBtn = document.getElementById('btn-toggle-ghost');
    const ghostStatus = document.getElementById('ghost-status-text');
    let isGhost = true;

    const syncGhostUI = (on) => {
        isGhost = !!on;
        if (ghostStatus) ghostStatus.textContent = isGhost ? 'Bật' : 'Tắt';
        ghostBtn?.classList.toggle('active', isGhost);
        ghostBtn?.setAttribute('aria-pressed', isGhost ? 'true' : 'false');
    };

    chrome.runtime.sendMessage({ type: 'GET_NATIVE_STATUS' }).then((res) => {
        if (typeof res?.isGhost === 'boolean') syncGhostUI(res.isGhost);
    }).catch(() => {});

    chrome.runtime.onMessage.addListener((msg) => {
        if (msg?.type === 'NATIVE_STATUS_BROADCAST' && typeof msg.isGhost === 'boolean') {
            syncGhostUI(msg.isGhost);
        }
    });

    if (ghostBtn) {
        ghostBtn.addEventListener('click', async () => {
            try {
                const res = await chrome.runtime.sendMessage({
                    type: 'NATIVE_COMMAND',
                    action: 'toggleGhost'
                });
                if (typeof res?.isGhost === 'boolean') {
                    syncGhostUI(res.isGhost);
                } else if (res?.success !== false) {
                    syncGhostUI(!isGhost);
                }
                showToast(isGhost ? 'Xuyên chuột đang bật: bấm xuyên phim để gõ code' : 'Xuyên chuột đang tắt: phim nhận chuột lại');
            } catch (err) {
                console.error(err);
            }
        });
    }

    // Direct URL Stream Modal
    const openDirectBtn = document.getElementById('btn-open-direct-url');
    const directModal = document.getElementById('direct-stream-modal');
    const directCloseBtn = document.getElementById('direct-modal-close-btn');
    const directSubmitBtn = document.getElementById('btn-submit-direct-float');
    const directUrlInput = document.getElementById('direct-url-input');
    const directTitleInput = document.getElementById('direct-title-input');

    if (openDirectBtn && directModal) {
        openDirectBtn.addEventListener('click', () => {
            directModal.classList.remove('hidden');
            directUrlInput?.focus();
        });
        directCloseBtn?.addEventListener('click', () => {
            directModal.classList.add('hidden');
        });
        directModal.addEventListener('click', (e) => {
            if (e.target === directModal) directModal.classList.add('hidden');
        });
        directSubmitBtn?.addEventListener('click', async () => {
            const url = directUrlInput?.value?.trim();
            const title = directTitleInput?.value?.trim() || 'Custom Stream';
            if (!url) {
                alert('Vui lòng nhập đường link stream hoặc URL video!');
                return;
            }
            directModal.classList.add('hidden');
            const isM3u8 = url.includes('.m3u8') || url.includes('.mp4');
            const isYt = url.includes('youtube.com') || url.includes('youtu.be');
            await chrome.runtime.sendMessage({
                type: 'FLOAT_VIDEO_REQUEST',
                videoInfo: {
                    src: isM3u8 ? url : '',
                    embedUrl: (!isM3u8 && !isYt) ? url : '',
                    pageUrl: isYt ? url : '',
                    title: title,
                    site: isYt ? 'youtube' : 'movie',
                    width: 640,
                    height: 360,
                    currentTime: 0
                }
            });
            showToast(`Đang phát nổi "${title}"`);
        });
    }

    // Category Buttons
    document.querySelectorAll('.cat-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            document.querySelectorAll('.cat-btn').forEach(b => b.classList.remove('active'));
            e.currentTarget.classList.add('active');
            currentCategory = e.currentTarget.dataset.cat || 'moi';
            currentGenre = '';
            currentCountry = '';
            const gSelect = document.getElementById('genre-select');
            const cSelect = document.getElementById('country-select');
            if (gSelect) gSelect.value = '';
            if (cSelect) cSelect.value = '';

            currentSearchKeyword = '';
            if (searchInput) searchInput.value = '';
            searchClear?.classList.add('hidden');
            searchDropdown?.classList.add('hidden');
            currentPage = 1;

            navigateView();
        });
    });

    // Genre Selector
    const genreSelect = document.getElementById('genre-select');
    genreSelect?.addEventListener('change', (e) => {
        currentGenre = e.target.value;
        currentCountry = '';
        const cSelect = document.getElementById('country-select');
        if (cSelect) cSelect.value = '';

        if (currentGenre) {
            document.querySelectorAll('.cat-btn').forEach(b => b.classList.remove('active'));
            currentPage = 1;
            navigateView();
        }
    });

    // Country Selector
    const countrySelect = document.getElementById('country-select');
    countrySelect?.addEventListener('change', (e) => {
        currentCountry = e.target.value;
        currentGenre = '';
        const gSelect = document.getElementById('genre-select');
        if (gSelect) gSelect.value = '';

        if (currentCountry) {
            document.querySelectorAll('.cat-btn').forEach(b => b.classList.remove('active'));
            currentPage = 1;
            navigateView();
        }
    });

    // Audio Sub-pills
    document.querySelectorAll('.audio-pill').forEach(pill => {
        pill.addEventListener('click', (e) => {
            document.querySelectorAll('.audio-pill').forEach(p => p.classList.remove('active'));
            e.currentTarget.classList.add('active');
            currentAudioFilter = e.currentTarget.dataset.filter || 'all';
            currentPage = 1;

            if (currentCategory === 'favorites') {
                loadFavorites();
            } else if (currentSearchKeyword) {
                searchMovies(currentSearchKeyword);
            } else {
                loadMovies();
            }
        });
    });

    // View Mode Switcher (Poster vs Cinema 16:9)
    const viewGridBtn = document.getElementById('view-grid-btn');
    const viewCinemaBtn = document.getElementById('view-cinema-btn');
    const movieGrid = document.getElementById('movie-grid');

    viewGridBtn?.addEventListener('click', () => {
        viewGridBtn.classList.add('active');
        viewCinemaBtn?.classList.remove('active');
        currentViewMode = 'view-poster';
        movieGrid?.classList.remove('view-cinema');
        movieGrid?.classList.add('view-poster');
        navigateView();
    });

    viewCinemaBtn?.addEventListener('click', () => {
        viewCinemaBtn.classList.add('active');
        viewGridBtn?.classList.remove('active');
        currentViewMode = 'view-cinema';
        movieGrid?.classList.remove('view-poster');
        movieGrid?.classList.add('view-cinema');
        navigateView();
    });

    // Pagination
    document.getElementById('prev-page-btn')?.addEventListener('click', () => {
        if (currentPage > 1) {
            currentPage--;
            loadMovies();
            window.scrollTo({ top: 300, behavior: 'smooth' });
        }
    });

    document.getElementById('next-page-btn')?.addEventListener('click', () => {
        currentPage++;
        loadMovies();
        window.scrollTo({ top: 300, behavior: 'smooth' });
    });

    // Modal Close
    document.getElementById('modal-close-btn')?.addEventListener('click', closeModal);
    document.getElementById('movie-modal')?.addEventListener('click', (e) => {
        if (e.target.id === 'movie-modal') closeModal();
    });

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') closeModal();
        if (e.key === '/' && document.activeElement !== searchInput) {
            e.preventDefault();
            searchInput?.focus();
        }
    });

    // Clear continue watching
    document.getElementById('clear-continue-btn')?.addEventListener('click', async () => {
        if (confirm('Bạn có chắc muốn xóa lịch sử xem gần đây?')) {
            if (typeof chrome !== 'undefined' && chrome.storage?.local) {
                await chrome.storage.local.set({ vibe_continue_watching: [] });
            } else {
                localStorage.removeItem('vibe_continue_watching');
            }
            loadContinueWatching();
        }
    });
}

// MARK: - Autocomplete Live Search Suggestions
function renderSearchSuggestions(items, query) {
    const dropdown = document.getElementById('search-suggestions');
    if (!dropdown) return;

    if (!items || items.length === 0) {
        dropdown.innerHTML = `<div style="padding: 12px; text-align: center; color: var(--text-muted); font-size: 12px;">Không tìm thấy phim khớp với "${escapeHtml(query)}"</div>`;
        dropdown.classList.remove('hidden');
        return;
    }

    dropdown.innerHTML = items.map(item => {
        const badges = [];
        if (item.isChieuRap) badges.push('<span class="suggestion-badge" style="background:#ef4444;color:#fff;">RẠP</span>');
        if (item.hasThuyetMinh) badges.push('<span class="suggestion-badge" style="background:#f59e0b;color:#000;">TM</span>');
        if (item.hasLongTieng) badges.push('<span class="suggestion-badge" style="background:#a855f7;color:#fff;">LT</span>');
        if (item.episode_current) badges.push(`<span class="suggestion-badge" style="background:rgba(255,255,255,0.12);color:#fff;">${escapeHtml(item.episode_current)}</span>`);

        return `
            <div class="suggestion-item" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}">
                <img class="suggestion-thumb" ${MovieImages.attr(item, 'poster')} width="40" height="56" alt="">
                <div class="suggestion-info">
                    <div class="suggestion-title">${escapeHtml(item.name)}</div>
                    <div class="suggestion-sub">${item.year ? item.year + ' · ' : ''}${escapeHtml(item.origin_name || '')}</div>
                    <div class="suggestion-badges">${badges.join('')}</div>
                </div>
            </div>
        `;
    }).join('');

    dropdown.classList.remove('hidden');

    dropdown.querySelectorAll('.suggestion-item').forEach(el => {
        el.addEventListener('click', () => {
            dropdown.classList.add('hidden');
            const slug = el.dataset.slug;
            const source = el.dataset.source;
            openMovieDetail(slug, source);
        });
    });
}

// MARK: - Home Page with Multi-Sections
async function loadHomePage() {
    const container = document.getElementById('home-sections-container');
    if (!container) return;

    // Show skeletons
    container.innerHTML = `
        <div class="home-section-skeleton"></div>
        <div class="home-section-skeleton"></div>
        <div class="home-section-skeleton"></div>
    `;

    try {
        const homeData = await MovieService.getHomeSections(currentSource);

        // Update Hero Spotlight with top 2026 cinema release
        if (homeData.spotlight) {
            renderHeroSpotlight(homeData.spotlight);
        } else {
            document.getElementById('hero-spotlight')?.classList.add('hidden');
        }

        // Render each category rail
        container.innerHTML = homeData.sections.map((sec, secIdx) => {
            return `
                <section class="home-section" data-sec-id="${sec.id}">
                    <div class="home-section-header">
                        <div class="home-section-title-wrap">
                            <div class="title-accent-bar"></div>
                            <div>
                                <h3 class="home-section-title">${escapeHtml(sec.title)}</h3>
                                <span class="home-section-subtitle">${escapeHtml(sec.subtitle)}</span>
                            </div>
                        </div>
                        <button class="view-all-btn" data-cat="${sec.categoryKey}">Xem tất cả →</button>
                    </div>

                    <div class="home-section-rail-wrap">
                        <button class="rail-nav-btn rail-prev" data-target="rail-${secIdx}" aria-label="Cuộn trái">‹</button>
                        <div id="rail-${secIdx}" class="home-section-rail">
                            ${renderMovieCardsHtml(sec.items)}
                        </div>
                        <button class="rail-nav-btn rail-next" data-target="rail-${secIdx}" aria-label="Cuộn phải">›</button>
                    </div>
                </section>
            `;
        }).join('');

        // Bind Rail scroll buttons
        container.querySelectorAll('.rail-nav-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const targetId = btn.dataset.target;
                const rail = document.getElementById(targetId);
                if (rail) {
                    const scrollAmount = rail.clientWidth * 0.75;
                    const direction = btn.classList.contains('rail-prev') ? -scrollAmount : scrollAmount;
                    rail.scrollBy({ left: direction, behavior: 'smooth' });
                }
            });
        });

        // Bind "Xem tất cả" buttons
        container.querySelectorAll('.view-all-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const targetCat = btn.dataset.cat;
                if (targetCat) {
                    document.querySelectorAll('.cat-btn').forEach(b => {
                        b.classList.toggle('active', b.dataset.cat === targetCat);
                    });
                    currentCategory = targetCat;
                    currentPage = 1;
                    navigateView();
                    window.scrollTo({ top: 0, behavior: 'smooth' });
                }
            });
        });

        // Bind Card Clicks
        bindCardClicks(container);

    } catch (e) {
        console.error('Failed to load home sections:', e);
        container.innerHTML = `<div style="text-align: center; color: #ff5555; padding: 48px;">
            Lỗi khi tải trang chủ từ nguồn ${currentSource.toUpperCase()}. Hãy thử chọn nguồn khác.
        </div>`;
    }
}

// MARK: - Render Movie Cards HTML
function renderMovieCardsHtml(items) {
    if (!items || items.length === 0) {
        return '<div style="color: var(--text-muted); font-size: 13px; padding: 24px;">Không có phim trong mục này.</div>';
    }

    return items.map(item => {
        const badges = [];
        if (item.isChieuRap) {
            badges.push('<span class="card-badge" style="background:#ef4444;color:#fff;">RẠP 2026</span>');
        }
        if (item.hasThuyetMinh) {
            badges.push('<span class="card-badge" style="background:#f59e0b;color:#000;">TM</span>');
        }
        if (item.hasLongTieng) {
            badges.push('<span class="card-badge" style="background:#a855f7;color:#fff;">LT</span>');
        }
        if (item.hasVietsub && !item.hasThuyetMinh && !item.hasLongTieng) {
            badges.push('<span class="card-badge" style="background:rgba(6,182,212,0.9);color:#fff;">VIETSUB</span>');
        }

        const ratingBadge = item.rating ? `<span class="card-badge-rating">${item.rating}</span>` : '';
        const epBadge = item.episode_current ? `<span class="card-ep-badge">${escapeHtml(item.episode_current)}</span>` : '';

        const imageKind = currentViewMode === 'view-cinema' ? 'wide' : 'poster';

        return `
            <div class="movie-card" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}">
                <div class="movie-poster-wrap">
                    <img class="movie-poster" ${MovieImages.attr(item, imageKind)} alt="${escapeAttr(item.name)}">
                    <div class="card-badges-top">${badges.join('')}</div>
                    ${ratingBadge}
                    ${epBadge}
                    <div class="card-hover-play">${PLAY_ICON_SVG}</div>
                </div>
                <div class="movie-info">
                    <div class="movie-title" title="${escapeAttr(item.name)}">${escapeHtml(item.name)}</div>
                    <div class="movie-origin">${escapeHtml(item.origin_name || item.year || '')}</div>
                    <div class="movie-footer">
                        <span>${item.year ? 'Năm ' + item.year : (item.quality || 'FHD')}</span>
                        <button type="button" class="card-quick-float" data-slug="${escapeAttr(item.slug)}" data-source="${escapeAttr(item.source || currentSource)}">Phát nổi</button>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

function bindCardClicks(container) {
    container.querySelectorAll('.card-quick-float').forEach(btn => {
        btn.addEventListener('click', async (e) => {
            e.stopPropagation();
            const slug = btn.dataset.slug;
            const source = btn.dataset.source || currentSource;
            const original = btn.textContent;
            btn.textContent = '...';
            btn.disabled = true;
            try {
                const ok = await quickFloatMovie(slug, source);
                btn.textContent = ok ? 'Đang phát' : 'Thử lại';
                if (ok) showToast('Đã phát nổi — cửa sổ tự né vùng code / nhập liệu');
            } catch (err) {
                btn.textContent = 'Thử lại';
            } finally {
                btn.disabled = false;
                setTimeout(() => { if (btn.textContent !== 'Đang phát') btn.textContent = original; }, 1600);
            }
        });
    });
    container.querySelectorAll('.movie-card').forEach(card => {
        card.addEventListener('click', () => {
            const slug = card.dataset.slug;
            const source = card.dataset.source || currentSource;
            openMovieDetail(slug, source);
        });
    });
}

async function quickFloatMovie(slug, source) {
    const detail = await MovieService.getDetail(slug, source);
    if (!detail?.episodes?.length) {
        openMovieDetail(slug, source);
        return false;
    }
    const servers = detail.episodes.filter(s => s.items?.length);
    if (!servers.length) {
        openMovieDetail(slug, source);
        return false;
    }

    const continueList = await MovieService.getContinueWatching();
    const cont = continueList.find(c => c.slug === slug);

    let server = servers[0];
    let ep = server.items[0];
    let serverIdx = MovieService.preferVietnameseServerIndex(servers);
    let epIdx = 0;
    server = servers[serverIdx] || servers[0];
    ep = server.items[0];

    if (cont) {
        if (cont.serverIdx != null && servers[cont.serverIdx]?.items?.[cont.epIdx ?? 0]) {
            // Keep saved server unless dead
            serverIdx = Number(cont.serverIdx) || 0;
            epIdx = Number(cont.epIdx) || 0;
            server = servers[serverIdx];
            ep = server.items[epIdx];
        } else if (cont.epName || cont.epSlug) {
            let best = null;
            for (let si = 0; si < servers.length; si++) {
                const matchIdx = servers[si].items.findIndex(item =>
                    (cont.epName && item.name === cont.epName) ||
                    (cont.epSlug && item.slug === cont.epSlug)
                );
                if (matchIdx >= 0) {
                    const rank = MovieService._serverAudioRank(servers[si]);
                    if (!best || rank < best.rank) best = { si, matchIdx, rank };
                }
            }
            if (best) {
                serverIdx = best.si;
                epIdx = best.matchIdx;
                server = servers[serverIdx];
                ep = server.items[epIdx];
            }
        }
    }

    // YouTube live channels → youtube float path
    if ((detail.source === 'livetv' || slug?.startsWith('livetv-')) && (ep.pageUrl?.includes('youtube') || ep.linkEmbed?.includes('youtube.com/embed'))) {
        const pageUrl = ep.pageUrl || (ep.linkEmbed ? ep.linkEmbed.replace('/embed/', '/watch?v=').replace(/\?autoplay=1/, '') : '');
        if (pageUrl) {
            const res = await chrome.runtime.sendMessage({
                type: 'FLOAT_VIDEO_REQUEST',
                videoInfo: {
                    pageUrl,
                    title: detail.name,
                    site: 'youtube',
                    width: 640,
                    height: 360,
                    currentTime: 0
                }
            });
            if (res?.success) {
                showToast('Đang phát nổi Lofi / Live YouTube');
                return true;
            }
            alert(formatFloatError(res));
            return false;
        }
    }

    const floated = await floatEpisode(ep, detail, server, {
        currentTime: Number(cont?.currentTime) || 0,
        duration: Number(cont?.duration) || 0,
        serverIdx,
        epIdx
    });
    return !!floated;
}

// MARK: - Cinema Hero Spotlight
function renderHeroSpotlight(spot) {
    const heroSection = document.getElementById('hero-spotlight');
    if (!heroSection || !spot) return;

    currentSpotlightMovie = spot;
    heroSection.classList.remove('hidden');

    const backdropEl = document.getElementById('hero-backdrop');
    if (backdropEl) {
        MovieImages.applyBackground(backdropEl, spot, 'hero');
    }

    document.getElementById('hero-title').textContent = spot.name;
    document.getElementById('hero-origin').textContent = `${spot.origin_name || ''} · Năm ${spot.year || '2026'}`;
    document.getElementById('hero-desc').textContent = spot.description || 'Bom tấn chiếu rạp chọn lọc với chất lượng hình ảnh sắc nét và bản lồng tiếng / thuyết minh chuẩn điện ảnh.';

    const ratingEl = document.getElementById('hero-rating');
    if (ratingEl) {
        ratingEl.textContent = spot.rating ? spot.rating : '8.8';
    }

    const audioBadgeEl = document.getElementById('hero-audio-badge');
    if (audioBadgeEl) {
        if (spot.hasThuyetMinh && spot.hasLongTieng) audioBadgeEl.textContent = 'TM + LT';
        else if (spot.hasThuyetMinh) audioBadgeEl.textContent = 'Thuyết Minh';
        else if (spot.hasLongTieng) audioBadgeEl.textContent = 'Lồng Tiếng';
        else audioBadgeEl.textContent = 'Vietsub FHD';
    }

    const floatBtn = document.getElementById('hero-float-btn');
    const detailBtn = document.getElementById('hero-detail-btn');
    const favBtn = document.getElementById('hero-fav-btn');

    floatBtn.onclick = () => {
        // Prefer continue-watching for this slug (resume mid-episode / đúng tập)
        quickFloatMovie(spot.slug, spot.source || 'kkphim');
    };

    detailBtn.onclick = () => {
        openMovieDetail(spot.slug, spot.source || 'kkphim');
    };

    favBtn.onclick = async () => {
        const isFav = await MovieService.toggleFavorite(spot);
        favBtn.textContent = isFav ? 'Đã lưu' : 'Lưu phim';
        showToast(isFav ? `Đã thêm "${spot.name}" vào Yêu Thích!` : `Đã bỏ khỏi Yêu Thích.`);
    };
}

// MARK: - Continue Watching
async function loadContinueWatching() {
    const continueSection = document.getElementById('continue-section');
    const rail = document.getElementById('continue-rail');
    if (!continueSection || !rail) return;

    const items = await MovieService.getContinueWatching();
    if (!items || items.length === 0) {
        continueSection.classList.add('hidden');
        return;
    }

    continueSection.classList.remove('hidden');
    rail.innerHTML = items.map((item, idx) => {
        const pct = MovieService.progressPercent(item);
        const progressHtml = pct > 0
            ? `<div class="continue-progress"><div class="continue-progress-bar" style="width:${pct}%"></div></div>`
            : '';
        return `
        <div class="continue-card" data-idx="${idx}">
            <img class="continue-thumb" ${MovieImages.attr(item, 'poster')} width="44" height="60" alt="">
            <div class="continue-info">
                <div class="continue-title" title="${escapeAttr(item.name)}">${escapeHtml(item.name)}</div>
                <div class="continue-ep">${escapeHtml(item.epName || 'Tập 1')}</div>
                <div class="continue-play">Bấm để phát nổi tiếp</div>
                ${progressHtml}
            </div>
        </div>
    `;
    }).join('');

    rail.querySelectorAll('.continue-card').forEach(card => {
        card.addEventListener('click', async () => {
            const idx = parseInt(card.dataset.idx);
            const item = items[idx];
            try {
                const ok = await floatContinueItem(item);
                if (ok) {
                    showToast(`Đang phát tiếp "${item.name} — ${item.epName || ''}"`);
                }
            } catch (err) {
                alert('Lỗi: ' + err.message);
            }
        });
    });
}

/** Resume continue-watching card with seek + playlist context. */
async function floatContinueItem(item) {
    if (!item) return false;
    let detail = null;
    try {
        detail = await MovieService.getDetail(item.slug, item.source || 'kkphim');
    } catch (e) {
        console.warn('[catalog] detail fetch for continue failed:', e);
    }

    let ep = {
        name: item.epName || 'Tập 1',
        slug: item.epSlug || '',
        linkM3u8: item.linkM3u8 || '',
        linkEmbed: item.linkEmbed || ''
    };
    let server = null;
    let serverIdx = Number(item.serverIdx) || 0;
    let epIdx = Number(item.epIdx) || 0;

    if (detail?.episodes?.length) {
        const servers = detail.episodes.filter(s => s.items?.length);
        // Keep saved serverIdx unless that server is dead
        if (item.serverIdx != null && servers[serverIdx]?.items?.[epIdx]) {
            server = servers[serverIdx];
            ep = server.items[epIdx] || ep;
            return await floatEpisode(ep, detail, server, {
                currentTime: Number(item.currentTime) || 0,
                duration: Number(item.duration) || 0,
                serverIdx,
                epIdx
            });
        }
        const found = MovieService.findEpisodeIndices(detail, ep);
        if (found.servers.length) {
            serverIdx = found.serverIdx;
            epIdx = found.epIdx;
            server = found.servers[serverIdx];
            ep = server.items[epIdx] || ep;
            return await floatEpisode(ep, detail, server, {
                currentTime: Number(item.currentTime) || 0,
                duration: Number(item.duration) || 0,
                serverIdx,
                epIdx
            });
        }
    }

    // Fallback: float saved links without full playlist
    const title = `${item.name} — ${item.epName || 'Tập 1'}`;
    const resumeAt = Number(item.currentTime) || 0;
    const res = await chrome.runtime.sendMessage({
        type: 'FLOAT_VIDEO_REQUEST',
        videoInfo: {
            src: item.linkM3u8 || '',
            embedUrl: item.linkEmbed || '',
            title,
            site: 'movie',
            width: 640,
            height: 360,
            currentTime: resumeAt
        }
    });
    if (res?.success) return true;
    alert(formatFloatError(res));
    return false;
}

// MARK: - Load Category Movies (Grid View)
async function loadMovies() {
    const grid = document.getElementById('movie-grid');
    const title = document.getElementById('section-title');
    const count = document.getElementById('result-count');

    // Skeletons
    grid.innerHTML = Array(12).fill('<div class="skeleton-card"></div>').join('');

    const catTitles = {
        'moi': 'Phim Mới Cập Nhật 2026',
        'chieurap': 'Phim Chiếu Rạp 2025 - 2026',
        'thuyetminh': 'Phim Thuyết Minh Mới Nhất',
        'longtieng': 'Phim Lồng Tiếng Mới Nhất',
        'bo': 'Phim Bộ Đang Hot',
        'le': 'Phim Lẻ Đỉnh Cao',
        'hoathinh': 'Anime & Hoạt Hình Mới Nhất',
        'tvshows': 'TV Shows Truyền Hình',
        'livetv': 'Kênh Truyền Hình & Luồng Trực Tiếp 24/7',
        'favorites': 'Phim Yêu Thích Của Bạn'
    };

    if (currentGenre) {
        title.textContent = `Thể loại: ${currentGenre.toUpperCase()}`;
    } else if (currentCountry) {
        title.textContent = `Quốc gia: ${currentCountry.toUpperCase()}`;
    } else {
        title.textContent = catTitles[currentCategory] || 'Danh Sách Phim';
    }
    count.textContent = '';

    try {
        let items = [];
        if (currentGenre) {
            items = await MovieService.getByGenre(currentGenre, currentPage);
        } else if (currentCountry) {
            items = await MovieService.getByCountry(currentCountry, currentPage);
        } else {
            items = await MovieService.getLatest(currentSource, currentCategory, currentPage);
        }

        // Apply Audio Sub-pill Filter
        if (currentAudioFilter === 'thuyetminh') {
            items = items.filter(it => it.hasThuyetMinh);
        } else if (currentAudioFilter === 'longtieng') {
            items = items.filter(it => it.hasLongTieng);
        } else if (currentAudioFilter === 'chieurap') {
            items = items.filter(it => it.isChieuRap);
        }

        renderGrid(items);
        updatePagination(true);
    } catch (err) {
        console.error('Failed to load movies:', err);
        grid.innerHTML = `<div style="grid-column: 1/-1; text-align: center; color: #ff5555; padding: 48px;">
            Không tải được dữ liệu phim từ nguồn ${currentSource.toUpperCase()}. Hãy thử chọn nguồn khác.
        </div>`;
    }
}

// MARK: - Search Movies
async function searchMovies(keyword) {
    const grid = document.getElementById('movie-grid');
    const title = document.getElementById('section-title');
    const count = document.getElementById('result-count');

    grid.innerHTML = Array(12).fill('<div class="skeleton-card"></div>').join('');
    title.textContent = `Kết quả tìm kiếm: "${keyword}"`;

    try {
        let items = await MovieService.search(keyword, currentSource, currentAudioFilter);
        count.textContent = `(${items.length} phim)`;
        renderGrid(items);
        updatePagination(false);
    } catch (err) {
        console.error('Search failed:', err);
        grid.innerHTML = `<div style="grid-column: 1/-1; text-align: center; color: #ff5555; padding: 48px;">
            Lỗi khi tìm kiếm trên ${currentSource.toUpperCase()}.
        </div>`;
    }
}

// MARK: - Favorites
async function loadFavorites() {
    const grid = document.getElementById('movie-grid');
    const title = document.getElementById('section-title');
    const count = document.getElementById('result-count');

    title.textContent = 'Phim Đã Lưu Yêu Thích';
    let items = await MovieService.getFavorites();

    if (currentAudioFilter === 'thuyetminh') items = items.filter(it => it.hasThuyetMinh);
    else if (currentAudioFilter === 'longtieng') items = items.filter(it => it.hasLongTieng);

    count.textContent = `(${items.length} phim)`;
    renderGrid(items);
    updatePagination(false);
}

// MARK: - Render Grid
function renderGrid(items) {
    const grid = document.getElementById('movie-grid');
    if (!items || items.length === 0) {
        grid.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--text-muted); padding: 60px; font-size: 14px;">Không tìm thấy phim phù hợp với tiêu chí lọc.</div>';
        return;
    }

    grid.innerHTML = renderMovieCardsHtml(items);
    bindCardClicks(grid);
}

function updatePagination(show) {
    const prevBtn = document.getElementById('prev-page-btn');
    const nextBtn = document.getElementById('next-page-btn');
    const indicator = document.getElementById('page-indicator');

    if (!show) {
        prevBtn?.classList.add('hidden');
        nextBtn?.classList.add('hidden');
        indicator?.classList.add('hidden');
        return;
    }

    prevBtn?.classList.remove('hidden');
    nextBtn?.classList.remove('hidden');
    indicator?.classList.remove('hidden');

    if (prevBtn) prevBtn.disabled = currentPage <= 1;
    if (indicator) indicator.textContent = `Trang ${currentPage}`;
}

// MARK: - Open Movie Detail Modal
async function openMovieDetail(slug, source = currentSource) {
    const modal = document.getElementById('movie-modal');
    modal?.classList.remove('hidden');

    // Loading state in modal
    document.getElementById('modal-title').textContent = 'Đang tải thông tin phim...';
    document.getElementById('modal-origin').textContent = '';
    document.getElementById('modal-desc').textContent = '';
    document.getElementById('server-tabs').innerHTML = '';
    document.getElementById('episodes-grid').innerHTML = '<span style="color: var(--text-muted); padding: 12px;">Đang tải danh sách tập phim...</span>';

    try {
        const detail = await MovieService.getDetail(slug, source);
        currentMovie = detail;

        document.getElementById('modal-title').textContent = detail.name;
        document.getElementById('modal-origin').textContent = `${detail.origin_name || ''} ${detail.year ? '· ' + detail.year : ''}`;
        const modalPoster = document.getElementById('modal-poster');
        const modalBackdrop = document.getElementById('modal-backdrop-img');
        MovieImages.apply(modalPoster, detail, 'poster');
        MovieImages.apply(modalBackdrop, { poster: detail.thumb, thumb: detail.poster }, 'hero');
        document.getElementById('modal-year').textContent = detail.year || '2026';
        document.getElementById('modal-quality').textContent = detail.quality || 'FHD';
        document.getElementById('modal-current-ep').textContent = detail.episode_current || 'Full';
        document.getElementById('modal-rating').textContent = detail.rating ? detail.rating : '8.8';
        document.getElementById('modal-source-badge').textContent = (detail.source || source).toUpperCase();

        document.getElementById('modal-time').textContent = detail.time ? detail.time : 'Chuẩn điện ảnh';
        document.getElementById('modal-genres').textContent = detail.genres?.length ? detail.genres.join(', ') : 'Phim Điện Ảnh';
        document.getElementById('modal-countries').textContent = detail.countries?.length ? detail.countries.join(', ') : 'Quốc tế';

        document.getElementById('modal-desc').textContent = detail.description || 'Chưa có tóm tắt cho bộ phim này.';

        // Favorite button
        const favBtn = document.getElementById('modal-fav-btn');
        if (favBtn) {
            favBtn.onclick = async () => {
                const isFav = await MovieService.toggleFavorite(detail);
                favBtn.textContent = isFav ? 'Đã lưu' : 'Lưu';
                showToast(isFav ? `Đã thêm "${detail.name}" vào Yêu Thích!` : `Đã bỏ khỏi Yêu Thích.`);
            };
        }

        renderEpisodes(detail.episodes);
    } catch (err) {
        console.error('Failed to get detail:', err);
        document.getElementById('modal-desc').textContent = 'Lỗi khi tải chi tiết phim từ máy chủ.';
    }
}

// MARK: - Render Episodes with Multi-Server Switcher
function renderEpisodes(episodes) {
    const tabsContainer = document.getElementById('server-tabs');
    const grid = document.getElementById('episodes-grid');

    if (!episodes || episodes.length === 0 || !episodes.some(s => s.items?.length)) {
        tabsContainer.innerHTML = '';
        grid.innerHTML = '<span style="color: var(--text-muted); padding: 12px;">Chưa có tập phim nào trên server này.</span>';
        return;
    }

    const validServers = episodes.filter(s => s.items && s.items.length > 0);
    let activeServerIdx = MovieService.preferVietnameseServerIndex(validServers);

    function renderServer(sIdx) {
        const server = validServers[sIdx];
        if (!server) return;

        // Render Tabs
        tabsContainer.innerHTML = validServers.map((s, idx) => {
            let extraClass = '';
            if (s.serverType === 'thuyetminh') {
                extraClass = 'server-tab-tm';
            } else if (s.serverType === 'longtieng') {
                extraClass = 'server-tab-lt';
            }

            return `
                <button class="server-tab-btn ${extraClass} ${idx === sIdx ? 'active' : ''}" data-idx="${idx}">
                    ${escapeHtml(s.serverName)} (${s.items.length} tập)
                </button>
            `;
        }).join('');

        // Bind Tab Clicks
        tabsContainer.querySelectorAll('.server-tab-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const newIdx = parseInt(e.currentTarget.dataset.idx);
                activeServerIdx = newIdx;
                renderServer(newIdx);
            });
        });

        // Render Episode Buttons
        grid.innerHTML = server.items.map((ep, idx) => `
            <button class="ep-btn" data-index="${idx}" title="Bấm để phát nổi trên Terminal/Cursor">
                ${escapeHtml(ep.name)}
            </button>
        `).join('');

        grid.querySelectorAll('.ep-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const idx = parseInt(e.currentTarget.dataset.index);
                const ep = server.items[idx];
                floatEpisode(ep, currentMovie, server, {
                    currentTime: 0,
                    duration: 0,
                    serverIdx: sIdx,
                    epIdx: idx
                });
            });
        });
    }

    renderServer(activeServerIdx);
}

// MARK: - Float Video Request
async function floatEpisode(ep, movie, server, opts = {}) {
    const indices = MovieService.findEpisodeIndices(movie, ep, server);
    const serverIdx = opts.serverIdx != null ? opts.serverIdx : indices.serverIdx;
    const epIdx = opts.epIdx != null ? opts.epIdx : indices.epIdx;
    const resumeAt = opts.currentTime != null ? Number(opts.currentTime) || 0 : 0;

    const srvTag = server?.serverType === 'thuyetminh' ? ' [Thuyết Minh]' : (server?.serverType === 'longtieng' ? ' [Lồng Tiếng]' : '');
    const title = `${movie ? movie.name : 'Movie'}${srvTag} — ${ep.name}`;

    const videoSrc = ep.linkM3u8 || '';
    const embedUrl = ep.linkEmbed || '';
    const movieContext = MovieService.buildMovieContext(movie, serverIdx, epIdx);

    try {
        const res = await chrome.runtime.sendMessage({
            type: 'FLOAT_VIDEO_REQUEST',
            videoInfo: {
                src: videoSrc,
                embedUrl: embedUrl,
                title: title,
                site: 'movie',
                width: 640,
                height: 360,
                currentTime: resumeAt,
                movieContext
            }
        });

        if (res?.success) {
            showToast(`Đang phát nổi "${title}"`);
            if (movie) {
                await MovieService.saveContinueWatching(movie, ep, {
                    currentTime: resumeAt,
                    duration: Number(opts.duration) || 0,
                    serverIdx,
                    epIdx
                });
                loadContinueWatching();
            }
            return true;
        } else {
            alert(formatFloatError(res));
            return false;
        }
    } catch (err) {
        console.error('Float request failed:', err);
        alert('Lỗi: ' + err.message);
        return false;
    }
}

function formatFloatError(res) {
    const err = (res && res.error) ? String(res.error) : 'Native app not responding';
    if (/not connected|install\.sh/i.test(err)) {
        return `${err}\nChạy scripts/install.sh rồi tải lại extension.`;
    }
    if (/Already opening/i.test(err)) {
        return 'Đang mở cửa sổ khác — đợi giây lát rồi thử lại.';
    }
    if (/timeout/i.test(err)) {
        return `${err}\nTải lại extension hoặc chạy lại install.sh.`;
    }
    return 'Lỗi khởi chạy cửa sổ nổi: ' + err;
}

// MARK: - Toast Notification
function showToast(message) {
    const existing = document.querySelector('.vibe-toast');
    if (existing) existing.remove();

    const toast = document.createElement('div');
    toast.className = 'vibe-toast';
    toast.innerHTML = `<span>${escapeHtml(message)}</span>`;
    document.body.appendChild(toast);

    setTimeout(() => {
        toast.style.opacity = '0';
        toast.style.transform = 'translateY(10px)';
        toast.style.transition = 'all 0.3s ease';
        setTimeout(() => toast.remove(), 350);
    }, 3500);
}

function closeModal() {
    document.getElementById('movie-modal')?.classList.add('hidden');
    currentMovie = null;
}

function escapeHtml(str) {
    return String(str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function escapeAttr(str) {
    return String(str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}
