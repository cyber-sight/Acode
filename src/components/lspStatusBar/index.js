import "./style.scss";

/**@type {HTMLElement | null} */
let $statusBar = null;

/**@type {number | null} */
let hideTimeout = null;

/**
 * @typedef {Object} LspStatusOptions
 * @property {string} message - The status message to display
 * @property {string} [icon] - Optional icon class name
 * @property {'info' | 'success' | 'warning' | 'error'} [type='info'] - Status type
 * @property {number | false} [duration=0] - Duration in ms, 0 for default (5000ms), false for persistent
 * @property {boolean} [showProgress=false] - Whether to show a progress indicator
 * @property {number} [progress] - Progress percentage (0-100)
 * @property {string} [title] - Optional title for the status
 */

/**
 * Show LSP status notification above quicktools
 * @param {LspStatusOptions} options - Status options
 */
export function showLspStatus(options) {
	const {
		message,
		icon = "autorenew",
		type = "info",
		duration = 0,
		showProgress = false,
		progress,
		title,
	} = options;

	// Clear any existing hide timeout
	if (hideTimeout) {
		clearTimeout(hideTimeout);
		hideTimeout = null;
	}

	// Remove existing status bar if present
	if ($statusBar) {
		$statusBar.remove();
	}

	const hasProgress = showProgress && typeof progress === "number";

	$statusBar = (
		<div id="lsp-status-bar" className={`lsp-status ${type}`}>
			<div className="lsp-status-content">
				<span className={`lsp-status-icon icon ${icon}`}></span>
				<div className="lsp-status-text">
					{title && <span className="lsp-status-title">{title}</span>}
					<span className="lsp-status-message">{message}</span>
				</div>
				{hasProgress && (
					<div className="lsp-status-progress">
						<span className="lsp-status-progress-text">
							{Math.round(progress)}%
						</span>
					</div>
				)}
			</div>
			<button
				type="button"
				className="lsp-status-close icon clearclose"
				onclick={hideLspStatus}
				aria-label="Close"
			></button>
		</div>
	);

	// Find the quicktools footer to insert before it
	const $footer = document.getElementById("quick-tools");
	if ($footer && $footer.parentNode) {
		$footer.parentNode.insertBefore($statusBar, $footer);
	} else {
		// Fallback: append to app
		const $app = document.getElementById("app") || document.body;
		$app.appendChild($statusBar);
	}

	// Auto-hide after duration (default 5000ms) unless duration is false
	if (duration !== false) {
		const timeout = duration || 5000;
		hideTimeout = window.setTimeout(() => {
			hideLspStatus();
		}, timeout);
	}

	return $statusBar;
}

/**
 * Hide the LSP status bar
 */
export function hideLspStatus() {
	if (hideTimeout) {
		clearTimeout(hideTimeout);
		hideTimeout = null;
	}

	if ($statusBar) {
		$statusBar.classList.add("hiding");
		setTimeout(() => {
			if ($statusBar) {
				$statusBar.remove();
				$statusBar = null;
			}
		}, 300);
	}
}

/**
 * Update the LSP status bar message/progress without creating a new one
 * @param {Partial<LspStatusOptions>} options - Options to update
 */
export function updateLspStatus(options) {
	if (!$statusBar) {
		// If no status bar exists, create one
		return showLspStatus({
			message: options.message || "",
			...options,
		});
	}

	const { message, progress, title, type } = options;

	if (message !== undefined) {
		const $message = $statusBar.querySelector(".lsp-status-message");
		if ($message) $message.textContent = message;
	}

	if (title !== undefined) {
		const $title = $statusBar.querySelector(".lsp-status-title");
		if ($title) $title.textContent = title;
	}

	if (progress !== undefined && typeof progress === "number") {
		const $progressText = $statusBar.querySelector(".lsp-status-progress-text");
		if ($progressText) {
			$progressText.textContent = `${Math.round(progress)}%`;
		}
	}

	if (type !== undefined) {
		$statusBar.className = `lsp-status ${type}`;
	}

	return $statusBar;
}

/**
 * Check if status bar is currently visible
 * @returns {boolean}
 */
export function isLspStatusVisible() {
	return $statusBar !== null && document.body.contains($statusBar);
}

export default {
	show: showLspStatus,
	hide: hideLspStatus,
	update: updateLspStatus,
	isVisible: isLspStatusVisible,
};
