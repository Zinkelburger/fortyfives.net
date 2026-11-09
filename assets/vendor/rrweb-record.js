// ../types/dist/types.js
var EventType = /* @__PURE__ */ function(EventType) {
	EventType[EventType["DomContentLoaded"] = 0] = "DomContentLoaded";
	EventType[EventType["Load"] = 1] = "Load";
	EventType[EventType["FullSnapshot"] = 2] = "FullSnapshot";
	EventType[EventType["IncrementalSnapshot"] = 3] = "IncrementalSnapshot";
	EventType[EventType["Meta"] = 4] = "Meta";
	EventType[EventType["Custom"] = 5] = "Custom";
	EventType[EventType["Plugin"] = 6] = "Plugin";
	EventType[EventType["Asset"] = 7] = "Asset";
	EventType[EventType["Annotation"] = 8] = "Annotation";
	return EventType;
}({});
var IncrementalSource = /* @__PURE__ */ function(IncrementalSource) {
	IncrementalSource[IncrementalSource["Mutation"] = 0] = "Mutation";
	IncrementalSource[IncrementalSource["MouseMove"] = 1] = "MouseMove";
	IncrementalSource[IncrementalSource["MouseInteraction"] = 2] = "MouseInteraction";
	IncrementalSource[IncrementalSource["Scroll"] = 3] = "Scroll";
	IncrementalSource[IncrementalSource["ViewportResize"] = 4] = "ViewportResize";
	IncrementalSource[IncrementalSource["Input"] = 5] = "Input";
	IncrementalSource[IncrementalSource["TouchMove"] = 6] = "TouchMove";
	IncrementalSource[IncrementalSource["MediaInteraction"] = 7] = "MediaInteraction";
	IncrementalSource[IncrementalSource["StyleSheetRule"] = 8] = "StyleSheetRule";
	IncrementalSource[IncrementalSource["CanvasMutation"] = 9] = "CanvasMutation";
	IncrementalSource[IncrementalSource["Font"] = 10] = "Font";
	IncrementalSource[IncrementalSource["Log"] = 11] = "Log";
	IncrementalSource[IncrementalSource["Drag"] = 12] = "Drag";
	IncrementalSource[IncrementalSource["StyleDeclaration"] = 13] = "StyleDeclaration";
	IncrementalSource[IncrementalSource["Selection"] = 14] = "Selection";
	IncrementalSource[IncrementalSource["AdoptedStyleSheet"] = 15] = "AdoptedStyleSheet";
	IncrementalSource[IncrementalSource["CustomElement"] = 16] = "CustomElement";
	return IncrementalSource;
}({});
var MouseInteractions = /* @__PURE__ */ function(MouseInteractions) {
	MouseInteractions[MouseInteractions["MouseUp"] = 0] = "MouseUp";
	MouseInteractions[MouseInteractions["MouseDown"] = 1] = "MouseDown";
	MouseInteractions[MouseInteractions["Click"] = 2] = "Click";
	MouseInteractions[MouseInteractions["ContextMenu"] = 3] = "ContextMenu";
	MouseInteractions[MouseInteractions["DblClick"] = 4] = "DblClick";
	MouseInteractions[MouseInteractions["Focus"] = 5] = "Focus";
	MouseInteractions[MouseInteractions["Blur"] = 6] = "Blur";
	MouseInteractions[MouseInteractions["TouchStart"] = 7] = "TouchStart";
	MouseInteractions[MouseInteractions["TouchMove_Departed"] = 8] = "TouchMove_Departed";
	MouseInteractions[MouseInteractions["TouchEnd"] = 9] = "TouchEnd";
	MouseInteractions[MouseInteractions["TouchCancel"] = 10] = "TouchCancel";
	return MouseInteractions;
}({});
var PointerTypes = /* @__PURE__ */ function(PointerTypes) {
	PointerTypes[PointerTypes["Mouse"] = 0] = "Mouse";
	PointerTypes[PointerTypes["Pen"] = 1] = "Pen";
	PointerTypes[PointerTypes["Touch"] = 2] = "Touch";
	return PointerTypes;
}({});
var CanvasContext = /* @__PURE__ */ function(CanvasContext) {
	CanvasContext[CanvasContext["2D"] = 0] = "2D";
	CanvasContext[CanvasContext["WebGL"] = 1] = "WebGL";
	CanvasContext[CanvasContext["WebGL2"] = 2] = "WebGL2";
	return CanvasContext;
}({});
var MediaInteractions = /* @__PURE__ */ function(MediaInteractions) {
	MediaInteractions[MediaInteractions["Play"] = 0] = "Play";
	MediaInteractions[MediaInteractions["Pause"] = 1] = "Pause";
	MediaInteractions[MediaInteractions["Seeked"] = 2] = "Seeked";
	MediaInteractions[MediaInteractions["VolumeChange"] = 3] = "VolumeChange";
	MediaInteractions[MediaInteractions["RateChange"] = 4] = "RateChange";
	return MediaInteractions;
}({});
var NodeType = /* @__PURE__ */ function(NodeType) {
	NodeType[NodeType["Document"] = 0] = "Document";
	NodeType[NodeType["DocumentType"] = 1] = "DocumentType";
	NodeType[NodeType["Element"] = 2] = "Element";
	NodeType[NodeType["Text"] = 3] = "Text";
	NodeType[NodeType["CDATA"] = 4] = "CDATA";
	NodeType[NodeType["Comment"] = 5] = "Comment";
	return NodeType;
}({});
// ../utils/dist/utils.js
var testableAccessors = {
	Node: [
		"childNodes",
		"parentNode",
		"parentElement",
		"textContent",
		"ownerDocument",
		"firstChild",
		"lastChild",
		"nextSibling",
		"previousSibling"
	],
	ShadowRoot: ["host", "styleSheets"],
	Element: [
		"shadowRoot",
		"querySelector",
		"querySelectorAll"
	],
	MutationObserver: []
};
var testableMethods = {
	Node: ["contains", "getRootNode"],
	ShadowRoot: ["getSelection"],
	Element: [],
	MutationObserver: ["constructor"]
};
var untaintedBasePrototype = {};
var untaintedBaseIframeCleanup = {};
var mutationObserverUsers = 0;
function angularZoneUnpatchedAlternative(key) {
	const angularUnpatchedVersionSymbol = globalThis?.Zone?.__symbol__?.(key);
	if (angularUnpatchedVersionSymbol && globalThis[angularUnpatchedVersionSymbol]) return globalThis[angularUnpatchedVersionSymbol];
	else return;
}
function getUntaintedPrototype(key) {
	if (untaintedBasePrototype[key]) return untaintedBasePrototype[key];
	const defaultObj = angularZoneUnpatchedAlternative(key) || globalThis[key];
	const defaultPrototype = defaultObj.prototype;
	const accessorNames = key in testableAccessors ? testableAccessors[key] : void 0;
	const isUntaintedAccessors = Boolean(accessorNames && accessorNames.every((accessor) => Boolean(Object.getOwnPropertyDescriptor(defaultPrototype, accessor)?.get?.toString().includes("[native code]"))));
	const methodNames = key in testableMethods ? testableMethods[key] : void 0;
	const isUntaintedMethods = Boolean(methodNames && methodNames.every((method) => typeof defaultPrototype[method] === "function" && defaultPrototype[method]?.toString().includes("[native code]")));
	if (isUntaintedAccessors && isUntaintedMethods) {
		untaintedBasePrototype[key] = defaultObj.prototype;
		return defaultObj.prototype;
	}
	try {
		const iframeEl = document.createElement("iframe");
		iframeEl.style.display = "none";
		document.body.appendChild(iframeEl);
		const win = iframeEl.contentWindow;
		if (!win) return defaultObj.prototype;
		const untaintedObject = win[key].prototype;
		if (!untaintedObject) {
			iframeEl.remove();
			return defaultPrototype;
		}
		const ua = navigator.userAgent;
		if (ua.includes("Safari") && !ua.includes("Chrome")) {
			iframeEl.classList.add("rr-block");
			iframeEl.setAttribute("__rrwebUntaintedMutationObserver", "");
			untaintedBaseIframeCleanup[key] = () => iframeEl.remove();
		} else iframeEl.remove();
		return untaintedBasePrototype[key] = untaintedObject;
	} catch {
		return defaultPrototype;
	}
}
var untaintedAccessorCache = {};
function getUntaintedAccessor(key, instance, accessor) {
	const cached = untaintedAccessorCache[key]?.[accessor];
	if (cached) return cached.call(instance);
	const untaintedPrototype = getUntaintedPrototype(key);
	const untaintedAccessor = Object.getOwnPropertyDescriptor(untaintedPrototype, accessor)?.get;
	if (!untaintedAccessor) return instance[accessor];
	(untaintedAccessorCache[key] ||= {})[accessor] = untaintedAccessor;
	return untaintedAccessor.call(instance);
}
var untaintedMethodCache = {};
function getUntaintedMethod(key, instance, method) {
	const cacheKey = `${key}.${String(method)}`;
	if (untaintedMethodCache[cacheKey]) return untaintedMethodCache[cacheKey].bind(instance);
	const untaintedMethod = getUntaintedPrototype(key)[method];
	if (typeof untaintedMethod !== "function") return instance[method];
	untaintedMethodCache[cacheKey] = untaintedMethod;
	return untaintedMethod.bind(instance);
}
function ownerDocument(n) {
	return getUntaintedAccessor("Node", n, "ownerDocument");
}
function childNodes(n) {
	return getUntaintedAccessor("Node", n, "childNodes");
}
function parentNode(n) {
	return getUntaintedAccessor("Node", n, "parentNode");
}
function parentElement(n) {
	return getUntaintedAccessor("Node", n, "parentElement");
}
function textContent(n) {
	return getUntaintedAccessor("Node", n, "textContent");
}
function firstChild(n) {
	return getUntaintedAccessor("Node", n, "firstChild");
}
function lastChild(n) {
	return getUntaintedAccessor("Node", n, "lastChild");
}
function nextSibling(n) {
	return getUntaintedAccessor("Node", n, "nextSibling");
}
function previousSibling(n) {
	return getUntaintedAccessor("Node", n, "previousSibling");
}
function contains(n, other) {
	return getUntaintedMethod("Node", n, "contains")(other);
}
function getRootNode(n) {
	return getUntaintedMethod("Node", n, "getRootNode")();
}
function host(n) {
	if (!n || !("host" in n)) return null;
	return getUntaintedAccessor("ShadowRoot", n, "host");
}
function styleSheets(n) {
	return n.styleSheets;
}
function shadowRoot(n) {
	if (!n || !("shadowRoot" in n)) return null;
	return getUntaintedAccessor("Element", n, "shadowRoot");
}
function querySelector(n, selectors) {
	return getUntaintedAccessor("Element", n, "querySelector")(selectors);
}
function querySelectorAll(n, selectors) {
	return getUntaintedAccessor("Element", n, "querySelectorAll")(selectors);
}
function mutationObserverCtor() {
	const prototype = getUntaintedPrototype("MutationObserver");
	mutationObserverUsers++;
	let stopCalled = false;
	return [prototype.constructor, () => {
		if (stopCalled) return;
		stopCalled = true;
		if (--mutationObserverUsers !== 0) return;
		const cleanup = untaintedBaseIframeCleanup["MutationObserver"];
		if (!cleanup) return;
		try {
			cleanup();
		} finally {
			delete untaintedBasePrototype["MutationObserver"];
			delete untaintedBaseIframeCleanup["MutationObserver"];
		}
	}];
}
var nowTimestamp = Date.now;
if (!/*@__PURE__*/ /[1-9][0-9]{12}/.test(Date.now().toString())) nowTimestamp = () => (/* @__PURE__ */ new Date()).getTime();
function patch(source, name, replacement) {
	try {
		if (!(name in source)) return () => {};
		const original = source[name];
		const wrapped = replacement(original);
		if (typeof wrapped === "function") {
			wrapped.prototype = wrapped.prototype || {};
			Object.defineProperties(wrapped, { __rrweb_original__: {
				enumerable: false,
				value: original
			} });
		}
		source[name] = wrapped;
		return () => {
			source[name] = original;
		};
	} catch {
		return () => {};
	}
}
var src_default = {
	ownerDocument,
	childNodes,
	parentNode,
	parentElement,
	textContent,
	firstChild,
	lastChild,
	nextSibling,
	previousSibling,
	contains,
	getRootNode,
	host,
	styleSheets,
	shadowRoot,
	querySelector,
	querySelectorAll,
	nowTimestamp,
	mutationObserverCtor,
	patch
};
// ../rrweb-snapshot/src/utils.ts
function isElement(n) {
	return n.nodeType === n.ELEMENT_NODE;
}
function isShadowRoot(n) {
	const hostEl = n && "host" in n && "mode" in n && src_default.host(n) || null;
	return Boolean(hostEl && "shadowRoot" in hostEl && src_default.shadowRoot(hostEl) === n);
}
/**
* To fix the issue https://github.com/rrweb-io/rrweb/issues/933.
* Some websites use polyfilled shadow dom and this function is used to detect this situation.
*/
function isNativeShadowDom(shadowRoot) {
	return Object.prototype.toString.call(shadowRoot) === "[object ShadowRoot]";
}
/**
* Browsers sometimes destructively modify the css rules they receive.
* This function tries to rectify the modifications the browser made to make it more cross platform compatible.
* @param cssText - output of `CSSStyleRule.cssText`
* @returns `cssText` with browser inconsistencies fixed.
*/
function fixBrowserCompatibilityIssuesInCSS(cssText) {
	/**
	* Chrome outputs `-webkit-background-clip` as `background-clip` in `CSSStyleRule.cssText`.
	* But then Chrome ignores `background-clip` as css input.
	* Re-introduce `-webkit-background-clip` to fix this issue.
	*/
	if (cssText.includes(" background-clip: text;") && !cssText.includes(" -webkit-background-clip: text;")) cssText = cssText.replace(/\sbackground-clip:\s*text;/g, " -webkit-background-clip: text; background-clip: text;");
	return cssText;
}
/**
* Browsers sometimes incorrectly escape `@import` on `.cssText` statements.
* This function tries to correct the escaping.
* more info: https://bugs.chromium.org/p/chromium/issues/detail?id=1472259
* @param cssImportRule
* @returns `cssText` with browser inconsistencies fixed, or null if not applicable.
*/
function escapeImportStatement(rule) {
	const { cssText } = rule;
	if (cssText.split("\"").length < 3) return cssText;
	const statement = ["@import", `url(${JSON.stringify(rule.href)})`];
	if (rule.layerName === "") statement.push(`layer`);
	else if (rule.layerName) statement.push(`layer(${rule.layerName})`);
	if (rule.supportsText) statement.push(`supports(${rule.supportsText})`);
	if (rule.media.length) statement.push(rule.media.mediaText);
	return statement.join(" ") + ";";
}
function stringifyStylesheet(s) {
	try {
		const rules = s.rules || s.cssRules;
		if (!rules) return null;
		let sheetHref = s.href;
		if (!sheetHref && s.ownerNode) sheetHref = s.ownerNode.baseURI;
		return fixBrowserCompatibilityIssuesInCSS(Array.from(rules, (rule) => stringifyRule(rule, sheetHref)).join(""));
	} catch (error) {
		return null;
	}
}
function stringifyRule(rule, sheetHref) {
	if (isCSSImportRule(rule)) {
		let importStringified;
		try {
			importStringified = stringifyStylesheet(rule.styleSheet) || escapeImportStatement(rule);
		} catch (error) {
			importStringified = rule.cssText;
		}
		if (rule.styleSheet.href) return absolutifyURLs(importStringified, rule.styleSheet.href);
		return importStringified;
	} else {
		let ruleStringified = rule.cssText;
		if (isCSSStyleRule(rule) && rule.selectorText.includes(":")) ruleStringified = fixSafariColons(ruleStringified);
		if (sheetHref) return absolutifyURLs(ruleStringified, sheetHref);
		return ruleStringified;
	}
}
function fixSafariColons(cssStringified) {
	return cssStringified.replace(/(\[(?:[\w-]+)[^\\])(:(?:[\w-]+)\])/gm, "$1\\$2");
}
function isCSSImportRule(rule) {
	return "styleSheet" in rule;
}
function isCSSStyleRule(rule) {
	return "selectorText" in rule;
}
var Mirror = class {
	idNodeMap = /* @__PURE__ */ new Map();
	nodeMetaMap = /* @__PURE__ */ new WeakMap();
	getId(n) {
		if (!n) return -1;
		return this.getMeta(n)?.id ?? -1;
	}
	getNode(id) {
		return this.idNodeMap.get(id) || null;
	}
	getIds() {
		return Array.from(this.idNodeMap.keys());
	}
	getMeta(n) {
		return this.nodeMetaMap.get(n) || null;
	}
	removeNodeFromMap(n) {
		const id = this.getId(n);
		this.idNodeMap.delete(id);
		if (n.childNodes) n.childNodes.forEach((childNode) => this.removeNodeFromMap(childNode));
		const shadowRoot = src_default.shadowRoot(n);
		if (shadowRoot) this.removeNodeFromMap(shadowRoot);
	}
	has(id) {
		return this.idNodeMap.has(id);
	}
	hasNode(node) {
		return this.nodeMetaMap.has(node);
	}
	add(n, meta) {
		const id = meta.id;
		this.idNodeMap.set(id, n);
		this.nodeMetaMap.set(n, meta);
	}
	replace(id, n) {
		const oldNode = this.getNode(id);
		if (oldNode) {
			const meta = this.nodeMetaMap.get(oldNode);
			if (meta) this.nodeMetaMap.set(n, meta);
		}
		this.idNodeMap.set(id, n);
	}
	reset() {
		this.idNodeMap = /* @__PURE__ */ new Map();
		this.nodeMetaMap = /* @__PURE__ */ new WeakMap();
	}
};
function createMirror() {
	return new Mirror();
}
function maskInputValue({ element, maskInputOptions, tagName, type, value, maskInputFn }) {
	let text = value || "";
	const actualType = type && toLowerCase(type);
	if (maskInputOptions[tagName.toLowerCase()] || actualType && maskInputOptions[actualType]) {
		if (maskInputFn) text = maskInputFn(text, element);
		else text = "*".repeat(text.length);
	}
	return text;
}
function toLowerCase(str) {
	return str.toLowerCase();
}
var ORIGINAL_ATTRIBUTE_NAME = "__rrweb_original__";
function is2DCanvasBlank(canvas) {
	const ctx = canvas.getContext("2d");
	if (!ctx) return true;
	const chunkSize = 50;
	for (let x = 0; x < canvas.width; x += chunkSize) for (let y = 0; y < canvas.height; y += chunkSize) {
		const getImageData = ctx.getImageData;
		const originalGetImageData = ORIGINAL_ATTRIBUTE_NAME in getImageData ? getImageData[ORIGINAL_ATTRIBUTE_NAME] : getImageData;
		if (new Uint32Array(originalGetImageData.call(ctx, x, y, Math.min(chunkSize, canvas.width - x), Math.min(chunkSize, canvas.height - y)).data.buffer).some((pixel) => pixel !== 0)) return false;
	}
	return true;
}
/**
* Get the type of an input element.
* This takes care of the case where a password input is changed to a text input.
* In this case, we continue to consider this of type password, in order to avoid leaking sensitive data
* where passwords should be masked.
*/
function getInputType(element) {
	const type = element.type;
	return element.hasAttribute("data-rr-is-password") ? "password" : type ? toLowerCase(type) : null;
}
/**
* Extracts the file extension from an a path, considering search parameters and fragments.
* @param path - Path to file
* @param baseURL - [optional] Base URL of the page, used to resolve relative paths. Defaults to current page URL.
*/
function extractFileExtension(path, baseURL) {
	let url;
	try {
		url = new URL(path, baseURL ?? window.location.href);
	} catch (err) {
		return null;
	}
	return url.pathname.match(/\.([0-9a-z]+)(?:$)/i)?.[1] ?? null;
}
function extractOrigin(url) {
	let origin = "";
	if (url.indexOf("//") > -1) origin = url.split("/").slice(0, 3).join("/");
	else origin = url.split("/")[0];
	origin = origin.split("?")[0];
	return origin;
}
var URL_IN_CSS_REF = /url\((?:(')([^']*)'|(")(.*?)"|([^)]*))\)/gm;
var URL_PROTOCOL_MATCH = /^(?:[a-z+]+:)?\/\//i;
var URL_WWW_MATCH = /^www\..*/i;
var DATA_URI = /^(data:)([^,]*),(.*)/i;
var BLOB_URI = /^blob:/i;
function absolutifyURLs(cssText, href) {
	return (cssText || "").replace(URL_IN_CSS_REF, (origin, quote1, path1, quote2, path2, path3) => {
		const filePath = path1 || path2 || path3;
		const maybeQuote = quote1 || quote2 || "";
		if (!filePath) return origin;
		if (URL_PROTOCOL_MATCH.test(filePath) || URL_WWW_MATCH.test(filePath)) return `url(${maybeQuote}${filePath}${maybeQuote})`;
		if (DATA_URI.test(filePath) || BLOB_URI.test(filePath)) return `url(${maybeQuote}${filePath}${maybeQuote})`;
		if (filePath[0] === "#") return `url(${maybeQuote}${filePath}${maybeQuote})`;
		if (filePath[0] === "/") return `url(${maybeQuote}${extractOrigin(href) + filePath}${maybeQuote})`;
		const filePathNoHash = filePath.split("#")[0];
		const maybeHash = filePath.substring(filePathNoHash.length);
		const stack = href.split("#")[0].split("/");
		const parts = filePathNoHash.split("/");
		stack.pop();
		for (const part of parts) if (part === ".") continue;
		else if (part === "..") stack.pop();
		else stack.push(part);
		return `url(${maybeQuote}${stack.join("/")}${maybeHash}${maybeQuote})`;
	});
}
var cssNormalizeBase = "(?:/\\*[^*]*\\*/)|[\\s;]";
var cssNormalizeRe = new RegExp(`${cssNormalizeBase}|\\b(0)px?`, "g");
var cssNormalizeReNoPx = new RegExp(cssNormalizeBase, "g");
/**
* Intention is to normalize by remove spaces, semicolons and CSS comments
* so that we can compare css as authored vs. output of stringifyStylesheet
*/
function normalizeCssString(cssText, _testNoPxNorm = false) {
	return _testNoPxNorm ? cssText.replace(cssNormalizeReNoPx, "") : cssText.replace(cssNormalizeRe, "$1");
}
/**
* Maps the output of stringifyStylesheet to individual text nodes of a <style> element
* which occurs when javascript is used to append to the style element
* and may also occur when browsers opt to break up large text nodes
* performance needs to be considered, see e.g. #1603
*/
function splitCssText(cssText, style, _testNoPxNorm = false) {
	const childNodes = Array.from(style.childNodes);
	const splits = [];
	let iterCount = 0;
	if (childNodes.length > 1 && cssText && typeof cssText === "string") {
		let cssTextNorm = normalizeCssString(cssText, _testNoPxNorm);
		const normFactor = cssTextNorm.length / cssText.length;
		for (let i = 1; i < childNodes.length; i++) if (childNodes[i].textContent && typeof childNodes[i].textContent === "string") {
			const textContentNorm = normalizeCssString(childNodes[i].textContent, _testNoPxNorm);
			const jLimit = 100;
			let j = 3;
			for (; j < textContentNorm.length; j++) {
				if (textContentNorm[j].match(/[a-zA-Z0-9]/) || textContentNorm.indexOf(textContentNorm.substring(0, j), 1) !== -1) continue;
				break;
			}
			for (; j < textContentNorm.length; j++) {
				let startSubstring = textContentNorm.substring(0, j);
				let cssNormSplits = cssTextNorm.split(startSubstring);
				let splitNorm = -1;
				if (cssNormSplits.length === 2) splitNorm = cssNormSplits[0].length;
				else if (cssNormSplits.length > 2 && cssNormSplits[0] === "" && childNodes[i - 1].textContent !== "") splitNorm = cssTextNorm.indexOf(startSubstring, 1);
				else if (cssNormSplits.length === 1) {
					startSubstring = startSubstring.substring(0, startSubstring.length - 1);
					cssNormSplits = cssTextNorm.split(startSubstring);
					if (cssNormSplits.length <= 1) {
						splits.push(cssText);
						return splits;
					}
					j = 101;
				} else if (j === textContentNorm.length - 1) splitNorm = cssTextNorm.indexOf(startSubstring);
				if (cssNormSplits.length >= 2 && j > jLimit) {
					const prevTextContent = childNodes[i - 1].textContent;
					if (prevTextContent && typeof prevTextContent === "string") {
						const prevMinLength = normalizeCssString(prevTextContent).length;
						splitNorm = cssTextNorm.indexOf(startSubstring, prevMinLength);
					}
					if (splitNorm === -1) splitNorm = cssNormSplits[0].length;
				}
				if (splitNorm !== -1) {
					let k = Math.floor(splitNorm / normFactor);
					for (; k > 0 && k < cssText.length;) {
						iterCount += 1;
						if (iterCount > 50 * childNodes.length) {
							splits.push(cssText);
							return splits;
						}
						const normPart = normalizeCssString(cssText.substring(0, k), _testNoPxNorm);
						if (normPart.length === splitNorm) {
							splits.push(cssText.substring(0, k));
							cssText = cssText.substring(k);
							cssTextNorm = cssTextNorm.substring(splitNorm);
							break;
						} else if (normPart.length < splitNorm) k += Math.max(1, Math.floor((splitNorm - normPart.length) / normFactor));
						else k -= Math.max(1, Math.floor((normPart.length - splitNorm) * normFactor));
					}
					break;
				}
			}
		}
	}
	splits.push(cssText);
	return splits;
}
function markCssSplits(cssText, style) {
	return splitCssText(cssText, style).join("/* rr_split */");
}
// ../rrweb-snapshot/src/snapshot.ts
var _id = 1;
var tagNameRegex = /* @__PURE__ */ new RegExp("[^a-z0-9-_:]");
function genId() {
	return _id++;
}
function getValidTagName(element) {
	if (element instanceof HTMLFormElement) return "form";
	const processedTagName = toLowerCase(element.tagName);
	if (tagNameRegex.test(processedTagName)) return "div";
	return processedTagName;
}
var canvasService;
var canvasCtx;
var SRCSET_NOT_SPACES = /^[^ \t\n\r\u000c]+/;
var SRCSET_COMMAS_OR_SPACES = /^[, \t\n\r\u000c]+/;
function getAbsoluteSrcsetString(doc, attributeValue) {
	if (attributeValue.trim() === "") return attributeValue;
	let pos = 0;
	function collectCharacters(regEx) {
		let chars;
		const match = regEx.exec(attributeValue.substring(pos));
		if (match) {
			chars = match[0];
			pos += chars.length;
			return chars;
		}
		return "";
	}
	const output = [];
	while (true) {
		collectCharacters(SRCSET_COMMAS_OR_SPACES);
		if (pos >= attributeValue.length) break;
		let url = collectCharacters(SRCSET_NOT_SPACES);
		if (url.slice(-1) === ",") {
			url = absoluteToDoc(doc, url.substring(0, url.length - 1));
			output.push(url);
		} else {
			let descriptorsStr = "";
			url = absoluteToDoc(doc, url);
			let inParens = false;
			while (true) {
				const c = attributeValue.charAt(pos);
				if (c === "") {
					output.push((url + descriptorsStr).trim());
					break;
				} else if (!inParens) {
					if (c === ",") {
						pos += 1;
						output.push((url + descriptorsStr).trim());
						break;
					} else if (c === "(") inParens = true;
				} else if (c === ")") inParens = false;
				descriptorsStr += c;
				pos += 1;
			}
		}
	}
	return output.join(", ");
}
var cachedDocument = /* @__PURE__ */ new WeakMap();
function absoluteToDoc(doc, attributeValue) {
	if (!attributeValue || attributeValue.trim() === "") return attributeValue;
	return getHref(doc, attributeValue);
}
function isSVGElement(el) {
	return Boolean(el.tagName === "svg" || el.ownerSVGElement);
}
function getHref(doc, customHref) {
	let a = cachedDocument.get(doc);
	if (!a) {
		a = doc.createElement("a");
		cachedDocument.set(doc, a);
	}
	if (!customHref) customHref = "";
	else if (customHref.startsWith("blob:") || customHref.startsWith("data:")) return customHref;
	a.setAttribute("href", customHref);
	return a.href;
}
function transformAttribute(doc, tagName, name, value) {
	if (!value) return value;
	if (name === "src" || name === "href" && !(tagName === "use" && value[0] === "#")) return absoluteToDoc(doc, value);
	else if (name === "xlink:href" && value[0] !== "#") return absoluteToDoc(doc, value);
	else if (name === "background" && [
		"table",
		"td",
		"th"
	].includes(tagName)) return absoluteToDoc(doc, value);
	else if (name === "srcset") return getAbsoluteSrcsetString(doc, value);
	else if (name === "style") return absolutifyURLs(value, getHref(doc));
	else if (tagName === "object" && name === "data") return absoluteToDoc(doc, value);
	return value;
}
function ignoreAttribute(tagName, name, _value) {
	return ["video", "audio"].includes(tagName) && toLowerCase(name) === "autoplay";
}
function _isBlockedElement(element, blockClass, blockSelector) {
	try {
		if (typeof blockClass === "string") {
			if (element.classList.contains(blockClass)) return true;
		} else for (let eIndex = element.classList.length; eIndex--;) {
			const className = element.classList[eIndex];
			if (blockClass.test(className)) return true;
		}
		if (blockSelector) return element.matches(blockSelector);
	} catch (e) {}
	return false;
}
function classMatchesRegex(node, regex, checkAncestors) {
	if (!node) return false;
	if (node.nodeType !== node.ELEMENT_NODE) {
		if (!checkAncestors) return false;
		return classMatchesRegex(src_default.parentNode(node), regex, checkAncestors);
	}
	for (let eIndex = node.classList.length; eIndex--;) {
		const className = node.classList[eIndex];
		if (regex.test(className)) return true;
	}
	if (!checkAncestors) return false;
	return classMatchesRegex(src_default.parentNode(node), regex, checkAncestors);
}
function needMaskingText(node, maskTextClass, maskTextSelector, checkAncestors) {
	let el;
	if (isElement(node)) {
		el = node;
		if (!src_default.childNodes(el).length) return false;
	} else if (src_default.parentElement(node) === null) return false;
	else el = src_default.parentElement(node);
	try {
		if (typeof maskTextClass === "string") {
			if (checkAncestors) {
				if (el.closest(`.${maskTextClass}`)) return true;
			} else if (el.classList.contains(maskTextClass)) return true;
		} else if (classMatchesRegex(el, maskTextClass, checkAncestors)) return true;
		if (maskTextSelector) {
			if (checkAncestors) {
				if (el.closest(maskTextSelector)) return true;
			} else if (el.matches(maskTextSelector)) return true;
		}
	} catch (e) {}
	return false;
}
function onceIframeLoaded(iframeEl, listener, iframeLoadTimeout) {
	const win = iframeEl.contentWindow;
	if (!win) return;
	let fired = false;
	let readyState;
	try {
		readyState = win.document.readyState;
	} catch (error) {
		return;
	}
	if (readyState !== "complete") {
		const timer = setTimeout(() => {
			if (!fired) {
				listener();
				fired = true;
			}
		}, iframeLoadTimeout);
		iframeEl.addEventListener("load", () => {
			clearTimeout(timer);
			fired = true;
			listener();
		});
		return;
	}
	const blankUrl = "about:blank";
	if (win.location.href !== blankUrl || iframeEl.src === blankUrl || iframeEl.src === "") {
		setTimeout(listener, 0);
		return iframeEl.addEventListener("load", listener);
	}
	iframeEl.addEventListener("load", listener);
}
function onceStylesheetLoaded(link, listener, styleSheetLoadTimeout) {
	let fired = false;
	let styleSheetLoaded;
	try {
		styleSheetLoaded = link.sheet;
	} catch (error) {
		return;
	}
	if (styleSheetLoaded) return;
	const timer = setTimeout(() => {
		if (!fired) {
			listener();
			fired = true;
		}
	}, styleSheetLoadTimeout);
	link.addEventListener("load", () => {
		clearTimeout(timer);
		fired = true;
		listener();
	});
}
function serializeNode(n, options) {
	const { doc, mirror, blockClass, blockSelector, needsMask, inlineStylesheet, maskInputOptions = {}, maskTextFn, maskInputFn, dataURLOptions = {}, inlineImages, recordCanvas, keepIframeSrcFn, newlyAddedElement = false, cssCaptured = false } = options;
	const rootId = getRootId(doc, mirror);
	switch (n.nodeType) {
		case n.DOCUMENT_NODE: if (n.compatMode !== "CSS1Compat") return {
			type: NodeType.Document,
			childNodes: [],
			compatMode: n.compatMode
		};
		else return {
			type: NodeType.Document,
			childNodes: []
		};
		case n.DOCUMENT_TYPE_NODE: return {
			type: NodeType.DocumentType,
			name: n.name,
			publicId: n.publicId,
			systemId: n.systemId,
			rootId
		};
		case n.ELEMENT_NODE: return serializeElementNode(n, {
			doc,
			blockClass,
			blockSelector,
			inlineStylesheet,
			maskInputOptions,
			maskInputFn,
			dataURLOptions,
			inlineImages,
			recordCanvas,
			keepIframeSrcFn,
			newlyAddedElement,
			rootId
		});
		case n.TEXT_NODE: return serializeTextNode(n, {
			doc,
			needsMask,
			maskTextFn,
			rootId,
			cssCaptured
		});
		case n.CDATA_SECTION_NODE: return {
			type: NodeType.CDATA,
			textContent: "",
			rootId
		};
		case n.COMMENT_NODE: return {
			type: NodeType.Comment,
			textContent: src_default.textContent(n) || "",
			rootId
		};
		default: return false;
	}
}
function getRootId(doc, mirror) {
	if (!mirror.hasNode(doc)) return void 0;
	const docId = mirror.getId(doc);
	return docId === 1 ? void 0 : docId;
}
function serializeTextNode(n, options) {
	const { needsMask, maskTextFn, rootId, cssCaptured } = options;
	const parent = src_default.parentNode(n);
	const parentTagName = parent && parent.tagName;
	let textContent = "";
	const isStyle = parentTagName === "STYLE" ? true : void 0;
	const isScript = parentTagName === "SCRIPT" ? true : void 0;
	if (isScript) textContent = "SCRIPT_PLACEHOLDER";
	else if (!cssCaptured) {
		textContent = src_default.textContent(n);
		if (isStyle && textContent) textContent = absolutifyURLs(textContent, getHref(options.doc));
	}
	if (!isStyle && !isScript && textContent && needsMask) textContent = maskTextFn ? maskTextFn(textContent, src_default.parentElement(n)) : textContent.replace(/[\S]/g, "*");
	return {
		type: NodeType.Text,
		textContent: textContent || "",
		rootId
	};
}
function serializeElementNode(n, options) {
	const { doc, blockClass, blockSelector, inlineStylesheet, maskInputOptions = {}, maskInputFn, dataURLOptions = {}, inlineImages, recordCanvas, keepIframeSrcFn, newlyAddedElement = false, rootId } = options;
	const needBlock = _isBlockedElement(n, blockClass, blockSelector);
	const tagName = getValidTagName(n);
	let attributes = {};
	const len = n.attributes.length;
	for (let i = 0; i < len; i++) {
		const attr = n.attributes[i];
		if (!ignoreAttribute(tagName, attr.name, attr.value)) attributes[attr.name] = transformAttribute(doc, tagName, toLowerCase(attr.name), attr.value);
	}
	if (tagName === "link" && inlineStylesheet) {
		const stylesheet = Array.from(doc.styleSheets).find((s) => {
			return s.href === n.href;
		});
		let cssText = null;
		if (stylesheet) cssText = stringifyStylesheet(stylesheet);
		if (cssText) {
			delete attributes.rel;
			delete attributes.href;
			attributes._cssText = cssText;
		}
	}
	if (tagName === "style" && n.sheet) {
		let cssText = stringifyStylesheet(n.sheet);
		if (cssText) {
			if (n.childNodes.length > 1) cssText = markCssSplits(cssText, n);
			attributes._cssText = cssText;
		}
	}
	if ([
		"input",
		"textarea",
		"select"
	].includes(tagName)) {
		const value = n.value;
		const checked = n.checked;
		if (attributes.type !== "radio" && attributes.type !== "checkbox" && attributes.type !== "submit" && attributes.type !== "button" && value) attributes.value = maskInputValue({
			element: n,
			type: getInputType(n),
			tagName,
			value,
			maskInputOptions,
			maskInputFn
		});
		else if (checked) attributes.checked = checked;
	}
	if (tagName === "option") {
		if (n.selected && !maskInputOptions["select"]) attributes.selected = true;
		else delete attributes.selected;
	}
	if (tagName === "dialog" && n.open) attributes.rr_open_mode = n.matches("dialog:modal") ? "modal" : "non-modal";
	if (tagName === "canvas" && recordCanvas) {
		if (n.__context === "2d") {
			if (!is2DCanvasBlank(n)) attributes.rr_dataURL = n.toDataURL(dataURLOptions.type, dataURLOptions.quality);
		} else if (!("__context" in n)) {
			const canvasDataURL = n.toDataURL(dataURLOptions.type, dataURLOptions.quality);
			const blankCanvas = doc.createElement("canvas");
			blankCanvas.width = n.width;
			blankCanvas.height = n.height;
			if (canvasDataURL !== blankCanvas.toDataURL(dataURLOptions.type, dataURLOptions.quality)) attributes.rr_dataURL = canvasDataURL;
		}
	}
	if (tagName === "img" && inlineImages) {
		if (!canvasService) {
			canvasService = doc.createElement("canvas");
			canvasCtx = canvasService.getContext("2d");
		}
		const image = n;
		const imageSrc = image.currentSrc || image.getAttribute("src") || "<unknown-src>";
		const priorCrossOrigin = image.crossOrigin;
		const recordInlineImage = () => {
			image.removeEventListener("load", recordInlineImage);
			try {
				canvasService.width = image.naturalWidth;
				canvasService.height = image.naturalHeight;
				canvasCtx.drawImage(image, 0, 0);
				attributes.rr_dataURL = canvasService.toDataURL(dataURLOptions.type, dataURLOptions.quality);
			} catch (err) {
				if (image.crossOrigin !== "anonymous") {
					image.crossOrigin = "anonymous";
					if (image.complete && image.naturalWidth !== 0) recordInlineImage();
					else image.addEventListener("load", recordInlineImage);
					return;
				} else console.warn(`Cannot inline img src=${imageSrc}! Error: ${err}`);
			}
			if (image.crossOrigin === "anonymous") priorCrossOrigin ? attributes.crossOrigin = priorCrossOrigin : image.removeAttribute("crossorigin");
		};
		if (image.complete && image.naturalWidth !== 0) recordInlineImage();
		else image.addEventListener("load", recordInlineImage);
	}
	if (["audio", "video"].includes(tagName)) {
		const mediaAttributes = attributes;
		mediaAttributes.rr_mediaState = n.paused ? "paused" : "played";
		mediaAttributes.rr_mediaCurrentTime = n.currentTime;
		mediaAttributes.rr_mediaPlaybackRate = n.playbackRate;
		mediaAttributes.rr_mediaMuted = n.muted;
		mediaAttributes.rr_mediaLoop = n.loop;
		mediaAttributes.rr_mediaVolume = n.volume;
	}
	if (!newlyAddedElement) {
		if (n.scrollLeft) attributes.rr_scrollLeft = n.scrollLeft;
		if (n.scrollTop) attributes.rr_scrollTop = n.scrollTop;
	}
	if (needBlock) {
		const { width, height } = n.getBoundingClientRect();
		attributes = {
			class: attributes.class,
			rr_width: `${width}px`,
			rr_height: `${height}px`
		};
	}
	if (tagName === "iframe" && !keepIframeSrcFn(attributes.src)) {
		if (!n.contentDocument) attributes.rr_src = attributes.src;
		delete attributes.src;
	}
	let isCustomElement;
	try {
		if (customElements.get(tagName)) isCustomElement = true;
	} catch (e) {}
	return {
		type: NodeType.Element,
		tagName,
		attributes,
		childNodes: [],
		isSVG: isSVGElement(n) || void 0,
		needBlock,
		rootId,
		isCustom: isCustomElement
	};
}
function lowerIfExists(maybeAttr) {
	if (maybeAttr === void 0 || maybeAttr === null) return "";
	else return maybeAttr.toLowerCase();
}
function slimDOMDefaults(_slimDOMOptions) {
	if (_slimDOMOptions === true || _slimDOMOptions === "all") return {
		script: true,
		comment: true,
		headFavicon: true,
		headWhitespace: true,
		headMetaSocial: true,
		headMetaRobots: true,
		headMetaHttpEquiv: true,
		headMetaVerification: true,
		headMetaAuthorship: _slimDOMOptions === "all",
		headMetaDescKeywords: _slimDOMOptions === "all",
		headTitleMutations: _slimDOMOptions === "all"
	};
	else if (_slimDOMOptions) return _slimDOMOptions;
	return {};
}
function slimDOMExcluded(sn, slimDOMOptions) {
	if (slimDOMOptions.comment && sn.type === NodeType.Comment) return true;
	else if (sn.type === NodeType.Element) {
		if (slimDOMOptions.script && (sn.tagName === "script" || sn.tagName === "link" && (sn.attributes.rel === "preload" && sn.attributes.as === "script" || sn.attributes.rel === "modulepreload") || sn.tagName === "link" && sn.attributes.rel === "prefetch" && typeof sn.attributes.href === "string" && extractFileExtension(sn.attributes.href) === "js")) return true;
		else if (slimDOMOptions.headFavicon && (sn.tagName === "link" && sn.attributes.rel === "shortcut icon" || sn.tagName === "meta" && (lowerIfExists(sn.attributes.name).match(/^msapplication-tile(image|color)$/) || lowerIfExists(sn.attributes.name) === "application-name" || lowerIfExists(sn.attributes.rel) === "icon" || lowerIfExists(sn.attributes.rel) === "apple-touch-icon" || lowerIfExists(sn.attributes.rel) === "shortcut icon"))) return true;
		else if (sn.tagName === "meta") {
			if (slimDOMOptions.headMetaDescKeywords && lowerIfExists(sn.attributes.name).match(/^description|keywords$/)) return true;
			else if (slimDOMOptions.headMetaSocial && (lowerIfExists(sn.attributes.property).match(/^(og|twitter|fb):/) || lowerIfExists(sn.attributes.name).match(/^(og|twitter):/) || lowerIfExists(sn.attributes.name) === "pinterest")) return true;
			else if (slimDOMOptions.headMetaRobots && (lowerIfExists(sn.attributes.name) === "robots" || lowerIfExists(sn.attributes.name) === "googlebot" || lowerIfExists(sn.attributes.name) === "bingbot")) return true;
			else if (slimDOMOptions.headMetaHttpEquiv && sn.attributes["http-equiv"] !== void 0) return true;
			else if (slimDOMOptions.headMetaAuthorship && (lowerIfExists(sn.attributes.name) === "author" || lowerIfExists(sn.attributes.name) === "generator" || lowerIfExists(sn.attributes.name) === "framework" || lowerIfExists(sn.attributes.name) === "publisher" || lowerIfExists(sn.attributes.name) === "progid" || lowerIfExists(sn.attributes.property).match(/^article:/) || lowerIfExists(sn.attributes.property).match(/^product:/))) return true;
			else if (slimDOMOptions.headMetaVerification && (lowerIfExists(sn.attributes.name) === "google-site-verification" || lowerIfExists(sn.attributes.name) === "yandex-verification" || lowerIfExists(sn.attributes.name) === "csrf-token" || lowerIfExists(sn.attributes.name) === "p:domain_verify" || lowerIfExists(sn.attributes.name) === "verify-v1" || lowerIfExists(sn.attributes.name) === "verification" || lowerIfExists(sn.attributes.name) === "shopify-checkout-api-token")) return true;
		}
	}
	return false;
}
function serializeNodeWithId(n, options) {
	const { doc, mirror, blockClass, blockSelector, maskTextClass, maskTextSelector, skipChild = false, inlineStylesheet = true, maskInputOptions = {}, maskTextFn, maskInputFn, slimDOMOptions, dataURLOptions = {}, inlineImages = false, recordCanvas = false, onSerialize, onIframeLoad, iframeLoadTimeout = 5e3, onStylesheetLoad, stylesheetLoadTimeout = 5e3, keepIframeSrcFn = () => false, newlyAddedElement = false, cssCaptured = false } = options;
	let { needsMask } = options;
	let { preserveWhiteSpace = true } = options;
	if (!needsMask) needsMask = needMaskingText(n, maskTextClass, maskTextSelector, needsMask === void 0);
	const _serializedNode = serializeNode(n, {
		doc,
		mirror,
		blockClass,
		blockSelector,
		needsMask,
		inlineStylesheet,
		maskInputOptions,
		maskTextFn,
		maskInputFn,
		dataURLOptions,
		inlineImages,
		recordCanvas,
		keepIframeSrcFn,
		newlyAddedElement,
		cssCaptured
	});
	if (!_serializedNode) {
		console.warn(n, "not serialized");
		return null;
	}
	let id;
	if (mirror.hasNode(n)) id = mirror.getId(n);
	else if (slimDOMExcluded(_serializedNode, slimDOMOptions) || !preserveWhiteSpace && _serializedNode.type === NodeType.Text && !_serializedNode.textContent.replace(/^\s+|\s+$/gm, "").length) id = -2;
	else id = genId();
	const serializedNode = Object.assign(_serializedNode, { id });
	mirror.add(n, serializedNode);
	if (id === -2) return null;
	if (onSerialize) onSerialize(n);
	let recordChild = !skipChild;
	if (serializedNode.type === NodeType.Element) {
		recordChild = recordChild && !serializedNode.needBlock;
		delete serializedNode.needBlock;
		const shadowRootEl = src_default.shadowRoot(n);
		if (shadowRootEl && isNativeShadowDom(shadowRootEl)) serializedNode.isShadowHost = true;
	}
	if ((serializedNode.type === NodeType.Document || serializedNode.type === NodeType.Element) && recordChild) {
		if (slimDOMOptions.headWhitespace && serializedNode.type === NodeType.Element && serializedNode.tagName === "head") preserveWhiteSpace = false;
		const bypassOptions = {
			doc,
			mirror,
			blockClass,
			blockSelector,
			needsMask,
			maskTextClass,
			maskTextSelector,
			skipChild,
			inlineStylesheet,
			maskInputOptions,
			maskTextFn,
			maskInputFn,
			slimDOMOptions,
			dataURLOptions,
			inlineImages,
			recordCanvas,
			preserveWhiteSpace,
			onSerialize,
			onIframeLoad,
			iframeLoadTimeout,
			onStylesheetLoad,
			stylesheetLoadTimeout,
			keepIframeSrcFn,
			cssCaptured: false
		};
		if (serializedNode.type === NodeType.Element && serializedNode.tagName === "textarea" && serializedNode.attributes.value !== void 0) {} else {
			if (serializedNode.type === NodeType.Element && serializedNode.attributes._cssText !== void 0 && typeof serializedNode.attributes._cssText === "string") bypassOptions.cssCaptured = true;
			for (const childN of Array.from(src_default.childNodes(n))) {
				const serializedChildNode = serializeNodeWithId(childN, bypassOptions);
				if (serializedChildNode) serializedNode.childNodes.push(serializedChildNode);
			}
		}
		let shadowRootEl = null;
		if (isElement(n) && (shadowRootEl = src_default.shadowRoot(n))) for (const childN of Array.from(src_default.childNodes(shadowRootEl))) {
			const serializedChildNode = serializeNodeWithId(childN, bypassOptions);
			if (serializedChildNode) {
				isNativeShadowDom(shadowRootEl) && (serializedChildNode.isShadow = true);
				serializedNode.childNodes.push(serializedChildNode);
			}
		}
	}
	const parent = src_default.parentNode(n);
	if (parent && isShadowRoot(parent) && isNativeShadowDom(parent)) serializedNode.isShadow = true;
	if (serializedNode.type === NodeType.Element && serializedNode.tagName === "iframe" && !_isBlockedElement(n, blockClass, blockSelector)) onceIframeLoaded(n, () => {
		const iframeDoc = n.contentDocument;
		if (iframeDoc && onIframeLoad) {
			const serializedIframeNode = serializeNodeWithId(iframeDoc, {
				doc: iframeDoc,
				mirror,
				blockClass,
				blockSelector,
				needsMask,
				maskTextClass,
				maskTextSelector,
				skipChild: false,
				inlineStylesheet,
				maskInputOptions,
				maskTextFn,
				maskInputFn,
				slimDOMOptions,
				dataURLOptions,
				inlineImages,
				recordCanvas,
				preserveWhiteSpace,
				onSerialize,
				onIframeLoad,
				iframeLoadTimeout,
				onStylesheetLoad,
				stylesheetLoadTimeout,
				keepIframeSrcFn
			});
			if (serializedIframeNode) onIframeLoad(n, serializedIframeNode);
		}
	}, iframeLoadTimeout);
	if (serializedNode.type === NodeType.Element && serializedNode.tagName === "link" && typeof serializedNode.attributes.rel === "string" && (serializedNode.attributes.rel === "stylesheet" || serializedNode.attributes.rel === "preload" && typeof serializedNode.attributes.href === "string" && extractFileExtension(serializedNode.attributes.href) === "css")) onceStylesheetLoaded(n, () => {
		if (onStylesheetLoad) {
			const serializedLinkNode = serializeNodeWithId(n, {
				doc,
				mirror,
				blockClass,
				blockSelector,
				needsMask,
				maskTextClass,
				maskTextSelector,
				skipChild: false,
				inlineStylesheet,
				maskInputOptions,
				maskTextFn,
				maskInputFn,
				slimDOMOptions,
				dataURLOptions,
				inlineImages,
				recordCanvas,
				preserveWhiteSpace,
				onSerialize,
				onIframeLoad,
				iframeLoadTimeout,
				onStylesheetLoad,
				stylesheetLoadTimeout,
				keepIframeSrcFn
			});
			if (serializedLinkNode) onStylesheetLoad(n, serializedLinkNode);
		}
	}, stylesheetLoadTimeout);
	return serializedNode;
}
function snapshot(n, options) {
	const { mirror = new Mirror(), blockClass = "rr-block", blockSelector = null, maskTextClass = "rr-mask", maskTextSelector = null, inlineStylesheet = true, inlineImages = false, recordCanvas = false, maskAllInputs = false, maskTextFn, maskInputFn, slimDOM = false, dataURLOptions, preserveWhiteSpace, onSerialize, onIframeLoad, iframeLoadTimeout, onStylesheetLoad, stylesheetLoadTimeout, keepIframeSrcFn = () => false } = options || {};
	return serializeNodeWithId(n, {
		doc: n,
		mirror,
		blockClass,
		blockSelector,
		maskTextClass,
		maskTextSelector,
		skipChild: false,
		inlineStylesheet,
		maskInputOptions: maskAllInputs === true ? {
			color: true,
			date: true,
			"datetime-local": true,
			email: true,
			month: true,
			number: true,
			range: true,
			search: true,
			tel: true,
			text: true,
			time: true,
			url: true,
			week: true,
			textarea: true,
			select: true,
			password: true
		} : maskAllInputs === false ? { password: true } : maskAllInputs,
		maskTextFn,
		maskInputFn,
		slimDOMOptions: slimDOMDefaults(slimDOM),
		dataURLOptions,
		inlineImages,
		recordCanvas,
		preserveWhiteSpace,
		onSerialize,
		onIframeLoad,
		iframeLoadTimeout,
		onStylesheetLoad,
		stylesheetLoadTimeout,
		keepIframeSrcFn,
		newlyAddedElement: false
	});
}
// ../rrdom/src/document.ts
/**
* This is designed as an abstract class so it should never be instantiated.
*/
var BaseRRNode = class BaseRRNode {
	parentElement = null;
	parentNode = null;
	ownerDocument;
	firstChild = null;
	lastChild = null;
	previousSibling = null;
	nextSibling = null;
	ELEMENT_NODE = 1;
	TEXT_NODE = 3;
	nodeType;
	nodeName;
	RRNodeType;
	constructor(..._args) {}
	get childNodes() {
		const childNodes = [];
		let childIterator = this.firstChild;
		while (childIterator) {
			childNodes.push(childIterator);
			childIterator = childIterator.nextSibling;
		}
		return childNodes;
	}
	contains(node) {
		if (!(node instanceof BaseRRNode)) return false;
		else if (node.ownerDocument !== this.ownerDocument) return false;
		else if (node === this) return true;
		while (node.parentNode) {
			if (node.parentNode === this) return true;
			node = node.parentNode;
		}
		return false;
	}
	appendChild(_newChild) {
		throw new Error(`RRDomException: Failed to execute 'appendChild' on 'RRNode': This RRNode type does not support this method.`);
	}
	insertBefore(_newChild, _refChild) {
		throw new Error(`RRDomException: Failed to execute 'insertBefore' on 'RRNode': This RRNode type does not support this method.`);
	}
	removeChild(_node) {
		throw new Error(`RRDomException: Failed to execute 'removeChild' on 'RRNode': This RRNode type does not support this method.`);
	}
	toString() {
		return "RRNode";
	}
};
// ../rrweb/src/utils.ts
function on(type, fn, target = document) {
	const options = {
		capture: true,
		passive: true
	};
	target.addEventListener(type, fn, options);
	return () => target.removeEventListener(type, fn, options);
}
var DEPARTED_MIRROR_ACCESS_WARNING = "Please stop import mirror directly. Instead of that,\r\nnow you can use replayer.getMirror() to access the mirror instance of a replayer,\r\nor you can use record.mirror to access the mirror instance during recording.";
/** @deprecated */
var _mirror = {
	map: {},
	getId() {
		console.error(DEPARTED_MIRROR_ACCESS_WARNING);
		return -1;
	},
	getNode() {
		console.error(DEPARTED_MIRROR_ACCESS_WARNING);
		return null;
	},
	removeNodeFromMap() {
		console.error(DEPARTED_MIRROR_ACCESS_WARNING);
	},
	has() {
		console.error(DEPARTED_MIRROR_ACCESS_WARNING);
		return false;
	},
	reset() {
		console.error(DEPARTED_MIRROR_ACCESS_WARNING);
	}
};
if (typeof window !== "undefined" && window.Proxy && window.Reflect) _mirror = new Proxy(_mirror, { get(target, prop, receiver) {
	if (prop === "map") console.error(DEPARTED_MIRROR_ACCESS_WARNING);
	return Reflect.get(target, prop, receiver);
} });
function throttle(func, wait, options = {}) {
	let timeout = null;
	let previous = 0;
	return function(...args) {
		const now = Date.now();
		if (!previous && options.leading === false) previous = now;
		const remaining = wait - (now - previous);
		const context = this;
		if (remaining <= 0 || remaining > wait) {
			if (timeout) {
				clearTimeout(timeout);
				timeout = null;
			}
			previous = now;
			func.apply(context, args);
		} else if (!timeout && options.trailing !== false) timeout = setTimeout(() => {
			previous = options.leading === false ? 0 : Date.now();
			timeout = null;
			func.apply(context, args);
		}, remaining);
	};
}
function hookSetter(target, key, d, isRevoked, win = window) {
	const original = win.Object.getOwnPropertyDescriptor(target, key);
	win.Object.defineProperty(target, key, isRevoked ? d : { set(value) {
		setTimeout(() => {
			d.set.call(this, value);
		}, 0);
		if (original && original.set) original.set.call(this, value);
	} });
	return () => hookSetter(target, key, original || {}, true);
}
function getWindowScroll(win) {
	const doc = win.document;
	return {
		left: doc.scrollingElement ? doc.scrollingElement.scrollLeft : win.pageXOffset !== void 0 ? win.pageXOffset : doc.documentElement.scrollLeft || doc?.body && src_default.parentElement(doc.body)?.scrollLeft || doc?.body?.scrollLeft || 0,
		top: doc.scrollingElement ? doc.scrollingElement.scrollTop : win.pageYOffset !== void 0 ? win.pageYOffset : doc?.documentElement.scrollTop || doc?.body && src_default.parentElement(doc.body)?.scrollTop || doc?.body?.scrollTop || 0
	};
}
function getWindowHeight() {
	return window.innerHeight || document.documentElement && document.documentElement.clientHeight || document.body && document.body.clientHeight;
}
function getWindowWidth() {
	return window.innerWidth || document.documentElement && document.documentElement.clientWidth || document.body && document.body.clientWidth;
}
/**
* Returns the given node as an HTMLElement if it is one, otherwise the parent node as an HTMLElement
* @param node - node to check
* @returns HTMLElement or null
*/
function closestElementOfNode(node) {
	if (!node) return null;
	return node.nodeType === node.ELEMENT_NODE ? node : src_default.parentElement(node);
}
/**
* Checks if the given element set to be blocked by rrweb
* @param node - node to check
* @param blockClass - class name to check
* @param blockSelector - css selectors to check
* @param checkAncestors - whether to search through parent nodes for the block class
* @returns true/false if the node was blocked or not
*/
function isBlocked(node, blockClass, blockSelector, checkAncestors) {
	if (!node) return false;
	const el = closestElementOfNode(node);
	if (!el) return false;
	try {
		if (typeof blockClass === "string") {
			if (el.classList.contains(blockClass)) return true;
			if (checkAncestors && el.closest("." + blockClass) !== null) return true;
		} else if (classMatchesRegex(el, blockClass, checkAncestors)) return true;
	} catch (e) {}
	if (blockSelector) {
		if (el.matches(blockSelector)) return true;
		if (checkAncestors && el.closest(blockSelector) !== null) return true;
	}
	return false;
}
function isSerialized(n, mirror) {
	return mirror.getId(n) !== -1;
}
function isIgnored(n, mirror, slimDOMOptions) {
	if (n.tagName === "TITLE" && slimDOMOptions.headTitleMutations) return true;
	return mirror.getId(n) === -2;
}
function isAncestorRemoved(target, mirror) {
	if (isShadowRoot(target)) return false;
	const id = mirror.getId(target);
	if (!mirror.has(id)) return true;
	const parent = src_default.parentNode(target);
	if (parent && parent.nodeType === target.DOCUMENT_NODE) return false;
	if (!parent) return true;
	return isAncestorRemoved(parent, mirror);
}
function legacy_isTouchEvent(event) {
	return Boolean(event.changedTouches);
}
function polyfill(win = window) {
	if ("NodeList" in win && !win.NodeList.prototype.forEach) win.NodeList.prototype.forEach = Array.prototype.forEach;
	if ("DOMTokenList" in win && !win.DOMTokenList.prototype.forEach) win.DOMTokenList.prototype.forEach = Array.prototype.forEach;
}
function isSerializedIframe(n, mirror) {
	return Boolean(n.nodeName === "IFRAME" && mirror.getMeta(n));
}
function isSerializedStylesheet(n, mirror) {
	return Boolean(n.nodeName === "LINK" && n.nodeType === n.ELEMENT_NODE && n.getAttribute && n.getAttribute("rel") === "stylesheet" && mirror.getMeta(n));
}
function hasShadowRoot(n) {
	if (!n) return false;
	if (n instanceof BaseRRNode && "shadowRoot" in n) return Boolean(n.shadowRoot);
	return Boolean(src_default.shadowRoot(n));
}
var StyleSheetMirror = class {
	id = 1;
	styleIDMap = /* @__PURE__ */ new WeakMap();
	idStyleMap = /* @__PURE__ */ new Map();
	getId(stylesheet) {
		return this.styleIDMap.get(stylesheet) ?? -1;
	}
	has(stylesheet) {
		return this.styleIDMap.has(stylesheet);
	}
	/**
	* @returns If the stylesheet is in the mirror, returns the id of the stylesheet. If not, return the new assigned id.
	*/
	add(stylesheet, id) {
		if (this.has(stylesheet)) return this.getId(stylesheet);
		let newId;
		if (id === void 0) newId = this.id++;
		else newId = id;
		this.styleIDMap.set(stylesheet, newId);
		this.idStyleMap.set(newId, stylesheet);
		return newId;
	}
	getStyle(id) {
		return this.idStyleMap.get(id) || null;
	}
	reset() {
		this.styleIDMap = /* @__PURE__ */ new WeakMap();
		this.idStyleMap = /* @__PURE__ */ new Map();
		this.id = 1;
	}
	generateId() {
		return this.id++;
	}
};
/**
* Get the direct shadow host of a node in shadow dom. Returns null if it is not in a shadow dom.
*/
function getShadowHost(n) {
	let shadowHost = null;
	if ("getRootNode" in n && src_default.getRootNode(n)?.nodeType === Node.DOCUMENT_FRAGMENT_NODE && src_default.host(src_default.getRootNode(n))) shadowHost = src_default.host(src_default.getRootNode(n));
	return shadowHost;
}
/**
* Get the root shadow host of a node in nested shadow doms. Returns the node itself if it is not in a shadow dom.
*/
function getRootShadowHost(n) {
	let rootShadowHost = n;
	let shadowHost;
	while (shadowHost = getShadowHost(rootShadowHost)) rootShadowHost = shadowHost;
	return rootShadowHost;
}
function shadowHostInDom(n) {
	const doc = src_default.ownerDocument(n);
	if (!doc) return false;
	const shadowHost = getRootShadowHost(n);
	return src_default.contains(doc, shadowHost);
}
function inDom(n) {
	const doc = src_default.ownerDocument(n);
	if (!doc) return false;
	return src_default.contains(doc, n) || shadowHostInDom(n);
}
// ../rrweb/src/record/mutation.ts
var moveKey = (id, parentId) => `${id}@${parentId}`;
/**
* controls behaviour of a MutationObserver
*/
var MutationBuffer = class {
	frozen = false;
	locked = false;
	texts = [];
	attributes = [];
	attributeMap = /* @__PURE__ */ new WeakMap();
	removes = [];
	mapRemoves = [];
	movedMap = {};
	/**
	* the browser MutationObserver emits multiple mutations after
	* a delay for performance reasons, making tracing added nodes hard
	* in our `processMutations` callback function.
	* For example, if we append an element el_1 into body, and then append
	* another element el_2 into el_1, these two mutations may be passed to the
	* callback function together when the two operations were done.
	* Generally we need to trace child nodes of newly added nodes, but in this
	* case if we count el_2 as el_1's child node in the first mutation record,
	* then we will count el_2 again in the second mutation record which was
	* duplicated.
	* To avoid of duplicate counting added nodes, we use a Set to store
	* added nodes and its child nodes during iterate mutation records. Then
	* collect added nodes from the Set which have no duplicate copy. But
	* this also causes newly added nodes will not be serialized with id ASAP,
	* which means all the id related calculation should be lazy too.
	*/
	addedSet = /* @__PURE__ */ new Set();
	movedSet = /* @__PURE__ */ new Set();
	droppedSet = /* @__PURE__ */ new Set();
	removesSubTreeCache = /* @__PURE__ */ new Set();
	mutationCb;
	blockClass;
	blockSelector;
	maskTextClass;
	maskTextSelector;
	inlineStylesheet;
	maskInputOptions;
	maskTextFn;
	maskInputFn;
	keepIframeSrcFn;
	recordCanvas;
	inlineImages;
	slimDOMOptions;
	dataURLOptions;
	doc;
	mirror;
	iframeManager;
	stylesheetManager;
	shadowDomManager;
	processedNodeManager;
	unattachedDoc;
	init(options) {
		[
			"mutationCb",
			"blockClass",
			"blockSelector",
			"maskTextClass",
			"maskTextSelector",
			"inlineStylesheet",
			"maskInputOptions",
			"maskTextFn",
			"maskInputFn",
			"keepIframeSrcFn",
			"recordCanvas",
			"inlineImages",
			"slimDOMOptions",
			"dataURLOptions",
			"doc",
			"mirror",
			"iframeManager",
			"stylesheetManager",
			"shadowDomManager",
			"processedNodeManager"
		].forEach((key) => {
			this[key] = options[key];
		});
	}
	freeze() {
		this.frozen = true;
	}
	unfreeze() {
		this.frozen = false;
		this.emit();
	}
	isFrozen() {
		return this.frozen;
	}
	lock() {
		this.locked = true;
	}
	unlock() {
		this.locked = false;
		this.emit();
	}
	processMutations = (mutations) => {
		mutations.forEach(this.processMutation);
		this.emit();
	};
	emit = () => {
		if (this.frozen || this.locked) return;
		const adds = [];
		const addedIds = /* @__PURE__ */ new Set();
		while (this.mapRemoves.length) this.mirror.removeNodeFromMap(this.mapRemoves.shift());
		for (const n of this.movedSet) {
			const parentNode = src_default.parentNode(n);
			if (this.removesSubTreeCache.has(parentNode) && !this.movedSet.has(parentNode)) continue;
			this.addedSet.add(n);
		}
		let n = null;
		let parentNode = null;
		let parentId = -1;
		let nextSibling = null;
		let ancestorBad = false;
		const missingParents = /* @__PURE__ */ new Set();
		const iter = this.addedSet.values();
		let curr = iter.next();
		while (this.addedSet.size) {
			if (n !== null && this.addedSet.has(src_default.previousSibling(n))) {
				nextSibling = n;
				n = src_default.previousSibling(n);
			} else {
				if (!this.addedSet.has(curr.value)) curr = iter.next();
				n = curr.value;
				while (true) {
					parentNode = src_default.parentNode(n);
					if (this.addedSet.has(parentNode)) {
						n = parentNode;
						continue;
					}
					break;
				}
				if (missingParents.has(parentNode)) parentNode = null;
				else if (parentNode) {
					if (!inDom(parentNode)) ancestorBad = true;
					else {
						ancestorBad = isSelfOrAncestorInSet(this.droppedSet, parentNode) || this.removesSubTreeCache.has(parentNode);
						if (ancestorBad && isSelfOrAncestorInSet(this.movedSet, n)) ancestorBad = false;
					}
					if (this.addedSet.has(src_default.lastChild(parentNode))) {
						n = src_default.lastChild(parentNode);
						nextSibling = null;
					} else while (true) {
						nextSibling = src_default.nextSibling(n);
						if (this.addedSet.has(nextSibling)) {
							n = nextSibling;
							continue;
						}
						break;
					}
					parentId = isShadowRoot(parentNode) ? this.mirror.getId(getShadowHost(n)) : this.mirror.getId(parentNode);
					if (parentId === -1 && parentNode.nodeType === Node.DOCUMENT_FRAGMENT_NODE) {
						const shadowHost = src_default.host(parentNode);
						parentId = this.mirror.getId(shadowHost);
					}
				}
			}
			this.addedSet.delete(n);
			if (!parentNode || parentId === -1) {
				missingParents.add(n);
				continue;
			} else if (ancestorBad) {
				this.droppedSet.add(n);
				continue;
			}
			let cssCaptured = false;
			if (n.nodeType === Node.TEXT_NODE) {
				const parentTag = parentNode.tagName;
				if (parentTag === "TEXTAREA") continue;
				else if (parentTag === "STYLE" && addedIds.has(parentId)) cssCaptured = true;
			}
			let nextId = nextSibling ? this.mirror.getId(nextSibling) : null;
			while (nextId === -2) {
				nextSibling = nextSibling && src_default.nextSibling(nextSibling);
				nextId = nextSibling && this.mirror.getId(nextSibling);
			}
			if (nextId === -1) {
				console.warn("Couldn't record new node. Couldn't find mirror id for nextSibling:", nextSibling);
				n = null;
				continue;
			}
			const sn = serializeNodeWithId(n, {
				doc: this.doc,
				mirror: this.mirror,
				blockClass: this.blockClass,
				blockSelector: this.blockSelector,
				maskTextClass: this.maskTextClass,
				maskTextSelector: this.maskTextSelector,
				skipChild: true,
				newlyAddedElement: true,
				inlineStylesheet: this.inlineStylesheet,
				maskInputOptions: this.maskInputOptions,
				maskTextFn: this.maskTextFn,
				maskInputFn: this.maskInputFn,
				slimDOMOptions: this.slimDOMOptions,
				dataURLOptions: this.dataURLOptions,
				recordCanvas: this.recordCanvas,
				inlineImages: this.inlineImages,
				onSerialize: (currentN) => {
					if (isSerializedIframe(currentN, this.mirror)) this.iframeManager.addIframe(currentN);
					if (isSerializedStylesheet(currentN, this.mirror)) this.stylesheetManager.trackLinkElement(currentN);
					if (hasShadowRoot(n)) this.shadowDomManager.addShadowRoot(src_default.shadowRoot(n), this.doc);
				},
				onIframeLoad: (iframe, childSn) => {
					this.iframeManager.attachIframe(iframe, childSn);
					this.shadowDomManager.observeAttachShadow(iframe);
				},
				onStylesheetLoad: (link, childSn) => {
					this.stylesheetManager.attachLinkElement(link, childSn);
				},
				cssCaptured
			});
			if (sn) {
				adds.push({
					parentId,
					nextId,
					node: sn
				});
				addedIds.add(sn.id);
			}
		}
		const payload = {
			texts: this.texts.map((text) => {
				const n = text.node;
				const parent = src_default.parentNode(n);
				if (parent && parent.tagName === "TEXTAREA") this.genTextAreaValueMutation(parent);
				return {
					id: this.mirror.getId(n),
					value: text.value
				};
			}).filter((text) => !addedIds.has(text.id)).filter((text) => this.mirror.has(text.id)),
			attributes: this.attributes.map((attribute) => {
				const { attributes } = attribute;
				if (typeof attributes.style === "string") {
					const diffAsStr = JSON.stringify(attribute.styleDiff);
					const unchangedAsStr = JSON.stringify(attribute._unchangedStyles);
					if (diffAsStr.length < attributes.style.length) {
						if ((diffAsStr + unchangedAsStr).split("var(").length === attributes.style.split("var(").length) attributes.style = attribute.styleDiff;
					}
				}
				return {
					id: this.mirror.getId(attribute.node),
					attributes
				};
			}).filter((attribute) => !addedIds.has(attribute.id)).filter((attribute) => this.mirror.has(attribute.id)),
			removes: this.removes,
			adds
		};
		if (!payload.texts.length && !payload.attributes.length && !payload.removes.length && !payload.adds.length) return;
		this.texts = [];
		this.attributes = [];
		this.attributeMap = /* @__PURE__ */ new WeakMap();
		this.removes = [];
		this.addedSet = /* @__PURE__ */ new Set();
		this.movedSet = /* @__PURE__ */ new Set();
		this.droppedSet = /* @__PURE__ */ new Set();
		this.removesSubTreeCache = /* @__PURE__ */ new Set();
		this.movedMap = {};
		this.mutationCb(payload);
	};
	genTextAreaValueMutation = (textarea) => {
		let item = this.attributeMap.get(textarea);
		if (!item) {
			item = {
				node: textarea,
				attributes: {},
				styleDiff: {},
				_unchangedStyles: {}
			};
			this.attributes.push(item);
			this.attributeMap.set(textarea, item);
		}
		const value = Array.from(src_default.childNodes(textarea), (cn) => src_default.textContent(cn) || "").join("");
		item.attributes.value = maskInputValue({
			element: textarea,
			maskInputOptions: this.maskInputOptions,
			tagName: textarea.tagName,
			type: getInputType(textarea),
			value,
			maskInputFn: this.maskInputFn
		});
	};
	processMutation = (m) => {
		if (isIgnored(m.target, this.mirror, this.slimDOMOptions)) return;
		switch (m.type) {
			case "characterData": {
				const value = src_default.textContent(m.target);
				if (!isBlocked(m.target, this.blockClass, this.blockSelector, false) && value !== m.oldValue) this.texts.push({
					value: needMaskingText(m.target, this.maskTextClass, this.maskTextSelector, true) && value ? this.maskTextFn ? this.maskTextFn(value, closestElementOfNode(m.target)) : value.replace(/[\S]/g, "*") : value,
					node: m.target
				});
				break;
			}
			case "attributes": {
				const target = m.target;
				const tagNameLower = toLowerCase(target.tagName);
				let attributeName = m.attributeName;
				let value = m.target.getAttribute(attributeName);
				if (attributeName === "value") {
					const type = getInputType(target);
					value = maskInputValue({
						element: target,
						maskInputOptions: this.maskInputOptions,
						tagName: target.tagName,
						type,
						value,
						maskInputFn: this.maskInputFn
					});
				}
				if (isBlocked(m.target, this.blockClass, this.blockSelector, false) || value === m.oldValue) return;
				let item = this.attributeMap.get(m.target);
				if (tagNameLower === "iframe" && attributeName === "src" && !this.keepIframeSrcFn(value)) {
					if (!target.contentDocument) attributeName = "rr_src";
					else return;
				}
				if (!item) {
					item = {
						node: m.target,
						attributes: {},
						styleDiff: {},
						_unchangedStyles: {}
					};
					this.attributes.push(item);
					this.attributeMap.set(m.target, item);
				}
				if (attributeName === "type" && tagNameLower === "input" && (m.oldValue || "").toLowerCase() === "password") target.setAttribute("data-rr-is-password", "true");
				if (!ignoreAttribute(tagNameLower, attributeName, value)) {
					item.attributes[attributeName] = transformAttribute(this.doc, tagNameLower, toLowerCase(attributeName), value);
					if (attributeName === "style") {
						if (!this.unattachedDoc) try {
							this.unattachedDoc = document.implementation.createHTMLDocument();
						} catch (e) {
							this.unattachedDoc = this.doc;
						}
						const old = this.unattachedDoc.createElement("span");
						if (m.oldValue) old.setAttribute("style", m.oldValue);
						for (const pname of Array.from(target.style)) {
							const newValue = target.style.getPropertyValue(pname);
							const newPriority = target.style.getPropertyPriority(pname);
							if (newValue !== old.style.getPropertyValue(pname) || newPriority !== old.style.getPropertyPriority(pname)) {
								if (newPriority === "") item.styleDiff[pname] = newValue;
								else item.styleDiff[pname] = [newValue, newPriority];
							} else item._unchangedStyles[pname] = [newValue, newPriority];
						}
						for (const pname of Array.from(old.style)) if (target.style.getPropertyValue(pname) === "") item.styleDiff[pname] = false;
					} else if (attributeName === "open" && target.tagName === "DIALOG") {
						if (target.matches("dialog:modal")) item.attributes["rr_open_mode"] = "modal";
						else item.attributes["rr_open_mode"] = "non-modal";
					}
				}
				break;
			}
			case "childList":
				/**
				* Parent is blocked, ignore all child mutations
				*/
				if (isBlocked(m.target, this.blockClass, this.blockSelector, true)) return;
				if (m.target.tagName === "TEXTAREA") {
					this.genTextAreaValueMutation(m.target);
					return;
				}
				m.addedNodes.forEach((n) => this.genAdds(n, m.target));
				m.removedNodes.forEach((n) => {
					if (!inDom(n)) this.shadowDomManager.removeShadowRootsIn(n);
					const nodeId = this.mirror.getId(n);
					const parentId = isShadowRoot(m.target) ? this.mirror.getId(src_default.host(m.target)) : this.mirror.getId(m.target);
					if (isBlocked(m.target, this.blockClass, this.blockSelector, false) || isIgnored(n, this.mirror, this.slimDOMOptions) || !isSerialized(n, this.mirror)) return;
					if (this.addedSet.has(n)) {
						deepDelete(this.addedSet, n);
						this.droppedSet.add(n);
					} else if (this.addedSet.has(m.target) && nodeId === -1) {} else if (isAncestorRemoved(m.target, this.mirror)) {} else if (this.movedSet.has(n) && this.movedMap[moveKey(nodeId, parentId)]) deepDelete(this.movedSet, n);
					else {
						this.removes.push({
							parentId,
							id: nodeId,
							isShadow: isShadowRoot(m.target) && isNativeShadowDom(m.target) ? true : void 0
						});
						processRemoves(n, this.removesSubTreeCache);
					}
					this.mapRemoves.push(n);
				});
		}
	};
	/**
	* Make sure you check if `n`'s parent is blocked before calling this function
	* */
	genAdds = (n, target) => {
		if (this.processedNodeManager.inOtherBuffer(n, this)) return;
		if (this.addedSet.has(n) || this.movedSet.has(n)) return;
		if (this.mirror.hasNode(n)) {
			if (isIgnored(n, this.mirror, this.slimDOMOptions)) return;
			this.movedSet.add(n);
			let targetId = null;
			if (target && this.mirror.hasNode(target)) targetId = this.mirror.getId(target);
			if (targetId && targetId !== -1) this.movedMap[moveKey(this.mirror.getId(n), targetId)] = true;
		} else {
			this.addedSet.add(n);
			this.droppedSet.delete(n);
		}
		if (!isBlocked(n, this.blockClass, this.blockSelector, false)) {
			src_default.childNodes(n).forEach((childN) => this.genAdds(childN));
			if (hasShadowRoot(n)) src_default.childNodes(src_default.shadowRoot(n)).forEach((childN) => {
				this.processedNodeManager.add(childN, this);
				this.genAdds(childN, n);
			});
		}
	};
};
/**
* Some utils to handle the mutation observer DOM records.
* It should be more clear to extend the native data structure
* like Set and Map, but currently Typescript does not support
* that.
*/
function deepDelete(addsSet, n) {
	addsSet.delete(n);
	src_default.childNodes(n).forEach((childN) => deepDelete(addsSet, childN));
}
function processRemoves(n, cache) {
	const queue = [n];
	while (queue.length) {
		const next = queue.pop();
		if (cache.has(next)) continue;
		cache.add(next);
		src_default.childNodes(next).forEach((n) => queue.push(n));
	}
}
function isSelfOrAncestorInSet(set, n) {
	if (set.size === 0) return false;
	return _isSelfOrAncestorInSet(set, n);
}
function _isSelfOrAncestorInSet(set, n) {
	if (set.has(n)) return true;
	const parent = src_default.parentNode(n);
	if (!parent) return false;
	return _isSelfOrAncestorInSet(set, parent);
}
// ../rrweb/src/record/error-handler.ts
var errorHandler;
function registerErrorHandler(handler) {
	errorHandler = handler;
}
function unregisterErrorHandler() {
	errorHandler = void 0;
}
/**
* Wrap callbacks in a wrapper that allows to pass errors to a configured `errorHandler` method.
*/
var callbackWrapper = (cb) => {
	if (!errorHandler) return cb;
	const rrwebWrapped = ((...rest) => {
		try {
			return cb(...rest);
		} catch (error) {
			if (errorHandler && errorHandler(error) === true) return;
			throw error;
		}
	});
	return rrwebWrapped;
};
// ../rrweb/src/record/observer.ts
var mutationBuffers = /* @__PURE__ */ new Set();
function getEventTarget(event) {
	try {
		if ("composedPath" in event) {
			const path = event.composedPath();
			if (path.length) return path[0];
		} else if ("path" in event && event.path.length) return event.path[0];
	} catch {}
	return event && event.target;
}
function initMutationObserver(options, rootEl) {
	const mutationBuffer = new MutationBuffer();
	mutationBuffers.add(mutationBuffer);
	mutationBuffer.init(options);
	const [ObserverCtor, releaseObserverConstructor] = mutationObserverCtor();
	const observer = new ObserverCtor(callbackWrapper(mutationBuffer.processMutations.bind(mutationBuffer)));
	observer.observe(rootEl, {
		attributes: true,
		attributeOldValue: true,
		characterData: true,
		characterDataOldValue: true,
		childList: true,
		subtree: true
	});
	const stop = () => {
		observer.disconnect();
		mutationBuffers.delete(mutationBuffer);
		releaseObserverConstructor();
	};
	return stop;
}
function initMoveObserver({ mousemoveCb, sampling, doc, mirror }) {
	if (sampling.mousemove === false) return () => {};
	const threshold = typeof sampling.mousemove === "number" ? sampling.mousemove : 50;
	const callbackThreshold = typeof sampling.mousemoveCallback === "number" ? sampling.mousemoveCallback : 500;
	let positions = [];
	let timeBaseline;
	const wrappedCb = throttle(callbackWrapper((source) => {
		const totalOffset = Date.now() - timeBaseline;
		mousemoveCb(positions.map((p) => {
			p.timeOffset -= totalOffset;
			return p;
		}), source);
		positions = [];
		timeBaseline = null;
	}), callbackThreshold);
	const updatePosition = callbackWrapper(throttle(callbackWrapper((evt) => {
		const target = getEventTarget(evt);
		const { clientX, clientY } = legacy_isTouchEvent(evt) ? evt.changedTouches[0] : evt;
		if (!timeBaseline) timeBaseline = nowTimestamp();
		positions.push({
			x: clientX,
			y: clientY,
			id: mirror.getId(target),
			timeOffset: nowTimestamp() - timeBaseline
		});
		wrappedCb(typeof DragEvent !== "undefined" && evt instanceof DragEvent ? IncrementalSource.Drag : evt instanceof MouseEvent ? IncrementalSource.MouseMove : IncrementalSource.TouchMove);
	}), threshold, { trailing: false }));
	const handlers = [
		on("mousemove", updatePosition, doc),
		on("touchmove", updatePosition, doc),
		on("drag", updatePosition, doc)
	];
	return callbackWrapper(() => {
		handlers.forEach((h) => h());
	});
}
function initMouseInteractionObserver({ mouseInteractionCb, doc, mirror, blockClass, blockSelector, sampling }) {
	if (sampling.mouseInteraction === false) return () => {};
	const disableMap = sampling.mouseInteraction === true || sampling.mouseInteraction === void 0 ? {} : sampling.mouseInteraction;
	const handlers = [];
	let currentPointerType = null;
	const getHandler = (eventKey) => {
		return (event) => {
			const target = getEventTarget(event);
			if (isBlocked(target, blockClass, blockSelector, true)) return;
			let pointerType = null;
			let thisEventKey = eventKey;
			if ("pointerType" in event) {
				switch (event.pointerType) {
					case "mouse":
						pointerType = PointerTypes.Mouse;
						break;
					case "touch":
						pointerType = PointerTypes.Touch;
						break;
					case "pen": pointerType = PointerTypes.Pen;
				}
				if (pointerType === PointerTypes.Touch) {
					if (MouseInteractions[eventKey] === MouseInteractions.MouseDown) thisEventKey = "TouchStart";
					else if (MouseInteractions[eventKey] === MouseInteractions.MouseUp) thisEventKey = "TouchEnd";
				} else if (pointerType === PointerTypes.Pen) {}
			} else if (legacy_isTouchEvent(event)) pointerType = PointerTypes.Touch;
			if (pointerType !== null) {
				currentPointerType = pointerType;
				if (thisEventKey.startsWith("Touch") && pointerType === PointerTypes.Touch || thisEventKey.startsWith("Mouse") && pointerType === PointerTypes.Mouse) pointerType = null;
			} else if (MouseInteractions[eventKey] === MouseInteractions.Click) {
				pointerType = currentPointerType;
				currentPointerType = null;
			}
			const e = legacy_isTouchEvent(event) ? event.changedTouches[0] : event;
			if (!e) return;
			const id = mirror.getId(target);
			const { clientX, clientY } = e;
			callbackWrapper(mouseInteractionCb)({
				type: MouseInteractions[thisEventKey],
				id,
				x: clientX,
				y: clientY,
				...pointerType !== null && { pointerType }
			});
		};
	};
	Object.keys(MouseInteractions).filter((key) => Number.isNaN(Number(key)) && !key.endsWith("_Departed") && disableMap[key] !== false).forEach((eventKey) => {
		let eventName = toLowerCase(eventKey);
		const handler = getHandler(eventKey);
		if (window.PointerEvent) switch (MouseInteractions[eventKey]) {
			case MouseInteractions.MouseDown:
			case MouseInteractions.MouseUp:
				eventName = eventName.replace("mouse", "pointer");
				break;
			case MouseInteractions.TouchStart:
			case MouseInteractions.TouchEnd: return;
		}
		handlers.push(on(eventName, handler, doc));
	});
	return callbackWrapper(() => {
		handlers.forEach((h) => h());
	});
}
function initScrollObserver({ scrollCb, doc, mirror, blockClass, blockSelector, sampling }) {
	return on("scroll", callbackWrapper(throttle(callbackWrapper((evt) => {
		const target = getEventTarget(evt);
		if (!target || isBlocked(target, blockClass, blockSelector, true)) return;
		const id = mirror.getId(target);
		if (target === doc && doc.defaultView) {
			const scrollLeftTop = getWindowScroll(doc.defaultView);
			scrollCb({
				id,
				x: scrollLeftTop.left,
				y: scrollLeftTop.top
			});
		} else scrollCb({
			id,
			x: target.scrollLeft,
			y: target.scrollTop
		});
	}), sampling.scroll || 100)), doc);
}
function initViewportResizeObserver({ viewportResizeCb }, { win }) {
	let lastH = -1;
	let lastW = -1;
	return on("resize", callbackWrapper(throttle(callbackWrapper(() => {
		const height = getWindowHeight();
		const width = getWindowWidth();
		if (lastH !== height || lastW !== width) {
			viewportResizeCb({
				width: Number(width),
				height: Number(height)
			});
			lastH = height;
			lastW = width;
		}
	}), 200)), win);
}
var INPUT_TAGS = [
	"INPUT",
	"TEXTAREA",
	"SELECT"
];
var lastInputValueMap = /* @__PURE__ */ new WeakMap();
function initInputObserver({ inputCb, doc, mirror, blockClass, blockSelector, ignoreClass, ignoreSelector, maskInputOptions, maskInputFn, sampling, userTriggeredOnInput }) {
	function eventHandler(event) {
		let target = getEventTarget(event);
		const userTriggered = event.isTrusted;
		const tagName = target && target.tagName;
		/**
		* If a site changes the value 'selected' of an option element, the value of its parent element, usually a select element, will be changed as well.
		* We can treat this change as a value change of the select element the current target belongs to.
		*/
		if (target && tagName === "OPTION") target = src_default.parentElement(target);
		if (!target || !tagName || INPUT_TAGS.indexOf(tagName) < 0 || isBlocked(target, blockClass, blockSelector, true)) return;
		if (target.classList.contains(ignoreClass) || ignoreSelector && target.matches(ignoreSelector)) return;
		let text = target.value;
		let isChecked = false;
		const type = getInputType(target) || "";
		if (type === "radio" || type === "checkbox") isChecked = target.checked;
		else if (maskInputOptions[tagName.toLowerCase()] || maskInputOptions[type]) text = maskInputValue({
			element: target,
			maskInputOptions,
			tagName,
			type,
			value: text,
			maskInputFn
		});
		cbWithDedup(target, userTriggeredOnInput ? {
			text,
			isChecked,
			userTriggered
		} : {
			text,
			isChecked
		});
		const name = target.name;
		if (type === "radio" && name && isChecked) doc.querySelectorAll(`input[type="radio"][name="${name}"]`).forEach((el) => {
			if (el !== target) {
				const text = el.value;
				cbWithDedup(el, userTriggeredOnInput ? {
					text,
					isChecked: !isChecked,
					userTriggered: false
				} : {
					text,
					isChecked: !isChecked
				});
			}
		});
	}
	function cbWithDedup(target, v) {
		const lastInputValue = lastInputValueMap.get(target);
		if (!lastInputValue || lastInputValue.text !== v.text || lastInputValue.isChecked !== v.isChecked) {
			lastInputValueMap.set(target, v);
			const id = mirror.getId(target);
			callbackWrapper(inputCb)({
				...v,
				id
			});
		}
	}
	const handlers = (sampling.input === "last" ? ["change"] : ["input", "change"]).map((eventName) => on(eventName, callbackWrapper(eventHandler), doc));
	const currentWindow = doc.defaultView;
	if (!currentWindow) return () => {
		handlers.forEach((h) => h());
	};
	const propertyDescriptor = currentWindow.Object.getOwnPropertyDescriptor(currentWindow.HTMLInputElement.prototype, "value");
	const hookProperties = [
		[currentWindow.HTMLInputElement.prototype, "value"],
		[currentWindow.HTMLInputElement.prototype, "checked"],
		[currentWindow.HTMLSelectElement.prototype, "value"],
		[currentWindow.HTMLTextAreaElement.prototype, "value"],
		[currentWindow.HTMLSelectElement.prototype, "selectedIndex"],
		[currentWindow.HTMLOptionElement.prototype, "selected"]
	];
	if (propertyDescriptor && propertyDescriptor.set) handlers.push(...hookProperties.map((p) => hookSetter(p[0], p[1], { set() {
		callbackWrapper(eventHandler)({
			target: this,
			isTrusted: false
		});
	} }, false, currentWindow)));
	return callbackWrapper(() => {
		handlers.forEach((h) => h());
	});
}
function getNestedCSSRulePositions(rule) {
	const positions = [];
	function recurse(childRule, pos) {
		if (hasNestedCSSRule("CSSGroupingRule") && childRule.parentRule instanceof CSSGroupingRule || hasNestedCSSRule("CSSMediaRule") && childRule.parentRule instanceof CSSMediaRule || hasNestedCSSRule("CSSSupportsRule") && childRule.parentRule instanceof CSSSupportsRule || hasNestedCSSRule("CSSConditionRule") && childRule.parentRule instanceof CSSConditionRule) {
			const index = Array.from(childRule.parentRule.cssRules).indexOf(childRule);
			pos.unshift(index);
			return recurse(childRule.parentRule, pos);
		} else if (childRule.parentStyleSheet) {
			const index = Array.from(childRule.parentStyleSheet.cssRules).indexOf(childRule);
			pos.unshift(index);
		}
		return pos;
	}
	return recurse(rule, positions);
}
/**
* For StyleSheets in Element, this function retrieves id of its host element.
* For adopted StyleSheets, this function retrieves its styleId from a styleMirror.
*/
function getIdAndStyleId(sheet, mirror, styleMirror) {
	let id, styleId;
	if (!sheet) return {};
	if (sheet.ownerNode) id = mirror.getId(sheet.ownerNode);
	else styleId = styleMirror.getId(sheet);
	return {
		styleId,
		id
	};
}
function initStyleSheetObserver({ styleSheetRuleCb, mirror, stylesheetManager }, { win }) {
	if (!win.CSSStyleSheet || !win.CSSStyleSheet.prototype) return () => {};
	const insertRule = win.CSSStyleSheet.prototype.insertRule;
	win.CSSStyleSheet.prototype.insertRule = new Proxy(insertRule, { apply: callbackWrapper((target, thisArg, argumentsList) => {
		const [rule, index] = argumentsList;
		const { id, styleId } = getIdAndStyleId(thisArg, mirror, stylesheetManager.styleMirror);
		if (id && id !== -1 || styleId && styleId !== -1) styleSheetRuleCb({
			id,
			styleId,
			adds: [{
				rule,
				index
			}]
		});
		return target.apply(thisArg, argumentsList);
	}) });
	win.CSSStyleSheet.prototype.addRule = function(selector, styleBlock, index = this.cssRules.length) {
		const rule = `${selector} { ${styleBlock} }`;
		return win.CSSStyleSheet.prototype.insertRule.apply(this, [rule, index]);
	};
	const deleteRule = win.CSSStyleSheet.prototype.deleteRule;
	win.CSSStyleSheet.prototype.deleteRule = new Proxy(deleteRule, { apply: callbackWrapper((target, thisArg, argumentsList) => {
		const [index] = argumentsList;
		const { id, styleId } = getIdAndStyleId(thisArg, mirror, stylesheetManager.styleMirror);
		if (id && id !== -1 || styleId && styleId !== -1) styleSheetRuleCb({
			id,
			styleId,
			removes: [{ index }]
		});
		return target.apply(thisArg, argumentsList);
	}) });
	win.CSSStyleSheet.prototype.removeRule = function(index) {
		return win.CSSStyleSheet.prototype.deleteRule.apply(this, [index]);
	};
	let replace;
	if (win.CSSStyleSheet.prototype.replace) {
		replace = win.CSSStyleSheet.prototype.replace;
		win.CSSStyleSheet.prototype.replace = new Proxy(replace, { apply: callbackWrapper((target, thisArg, argumentsList) => {
			const [text] = argumentsList;
			const { id, styleId } = getIdAndStyleId(thisArg, mirror, stylesheetManager.styleMirror);
			if (id && id !== -1 || styleId && styleId !== -1) styleSheetRuleCb({
				id,
				styleId,
				replace: text
			});
			return target.apply(thisArg, argumentsList);
		}) });
	}
	let replaceSync;
	if (win.CSSStyleSheet.prototype.replaceSync) {
		replaceSync = win.CSSStyleSheet.prototype.replaceSync;
		win.CSSStyleSheet.prototype.replaceSync = new Proxy(replaceSync, { apply: callbackWrapper((target, thisArg, argumentsList) => {
			const [text] = argumentsList;
			const { id, styleId } = getIdAndStyleId(thisArg, mirror, stylesheetManager.styleMirror);
			if (id && id !== -1 || styleId && styleId !== -1) styleSheetRuleCb({
				id,
				styleId,
				replaceSync: text
			});
			return target.apply(thisArg, argumentsList);
		}) });
	}
	const supportedNestedCSSRuleTypes = {};
	if (canMonkeyPatchNestedCSSRule("CSSGroupingRule")) supportedNestedCSSRuleTypes.CSSGroupingRule = win.CSSGroupingRule;
	else {
		if (canMonkeyPatchNestedCSSRule("CSSMediaRule")) supportedNestedCSSRuleTypes.CSSMediaRule = win.CSSMediaRule;
		if (canMonkeyPatchNestedCSSRule("CSSConditionRule")) supportedNestedCSSRuleTypes.CSSConditionRule = win.CSSConditionRule;
		if (canMonkeyPatchNestedCSSRule("CSSSupportsRule")) supportedNestedCSSRuleTypes.CSSSupportsRule = win.CSSSupportsRule;
	}
	const unmodifiedFunctions = {};
	Object.entries(supportedNestedCSSRuleTypes).forEach(([typeKey, type]) => {
		unmodifiedFunctions[typeKey] = {
			insertRule: type.prototype.insertRule,
			deleteRule: type.prototype.deleteRule
		};
		type.prototype.insertRule = new Proxy(unmodifiedFunctions[typeKey].insertRule, { apply: callbackWrapper((target, thisArg, argumentsList) => {
			const [rule, index] = argumentsList;
			const { id, styleId } = getIdAndStyleId(thisArg.parentStyleSheet, mirror, stylesheetManager.styleMirror);
			if (id && id !== -1 || styleId && styleId !== -1) styleSheetRuleCb({
				id,
				styleId,
				adds: [{
					rule,
					index: [...getNestedCSSRulePositions(thisArg), index || 0]
				}]
			});
			return target.apply(thisArg, argumentsList);
		}) });
		type.prototype.deleteRule = new Proxy(unmodifiedFunctions[typeKey].deleteRule, { apply: callbackWrapper((target, thisArg, argumentsList) => {
			const [index] = argumentsList;
			const { id, styleId } = getIdAndStyleId(thisArg.parentStyleSheet, mirror, stylesheetManager.styleMirror);
			if (id && id !== -1 || styleId && styleId !== -1) styleSheetRuleCb({
				id,
				styleId,
				removes: [{ index: [...getNestedCSSRulePositions(thisArg), index] }]
			});
			return target.apply(thisArg, argumentsList);
		}) });
	});
	return callbackWrapper(() => {
		win.CSSStyleSheet.prototype.insertRule = insertRule;
		win.CSSStyleSheet.prototype.deleteRule = deleteRule;
		replace && (win.CSSStyleSheet.prototype.replace = replace);
		replaceSync && (win.CSSStyleSheet.prototype.replaceSync = replaceSync);
		Object.entries(supportedNestedCSSRuleTypes).forEach(([typeKey, type]) => {
			type.prototype.insertRule = unmodifiedFunctions[typeKey].insertRule;
			type.prototype.deleteRule = unmodifiedFunctions[typeKey].deleteRule;
		});
	});
}
function initAdoptedStyleSheetObserver({ mirror, stylesheetManager }, host) {
	let hostId = null;
	if (host.nodeName === "#document") hostId = mirror.getId(host);
	else hostId = mirror.getId(src_default.host(host));
	const patchTarget = host.nodeName === "#document" ? host.defaultView?.Document : host.ownerDocument?.defaultView?.ShadowRoot;
	const originalPropertyDescriptor = patchTarget?.prototype ? Object.getOwnPropertyDescriptor(patchTarget?.prototype, "adoptedStyleSheets") : void 0;
	if (hostId === null || hostId === -1 || !patchTarget || !originalPropertyDescriptor) return () => {};
	Object.defineProperty(host, "adoptedStyleSheets", {
		configurable: originalPropertyDescriptor.configurable,
		enumerable: originalPropertyDescriptor.enumerable,
		get() {
			return originalPropertyDescriptor.get?.call(this);
		},
		set(sheets) {
			const result = originalPropertyDescriptor.set?.call(this, sheets);
			if (hostId !== null && hostId !== -1) try {
				stylesheetManager.adoptStyleSheets(sheets, hostId);
			} catch (e) {}
			return result;
		}
	});
	return callbackWrapper(() => {
		Object.defineProperty(host, "adoptedStyleSheets", {
			configurable: originalPropertyDescriptor.configurable,
			enumerable: originalPropertyDescriptor.enumerable,
			get: originalPropertyDescriptor.get,
			set: originalPropertyDescriptor.set
		});
	});
}
function initStyleDeclarationObserver({ styleDeclarationCb, mirror, ignoreCSSAttributes, stylesheetManager }, { win }) {
	const setProperty = win.CSSStyleDeclaration.prototype.setProperty;
	win.CSSStyleDeclaration.prototype.setProperty = new Proxy(setProperty, { apply: callbackWrapper((target, thisArg, argumentsList) => {
		const [property, value, priority] = argumentsList;
		if (ignoreCSSAttributes.has(property)) return setProperty.apply(thisArg, [
			property,
			value,
			priority
		]);
		const { id, styleId } = getIdAndStyleId(thisArg.parentRule?.parentStyleSheet, mirror, stylesheetManager.styleMirror);
		if (id && id !== -1 || styleId && styleId !== -1) styleDeclarationCb({
			id,
			styleId,
			set: {
				property,
				value,
				priority
			},
			index: getNestedCSSRulePositions(thisArg.parentRule)
		});
		return target.apply(thisArg, argumentsList);
	}) });
	const removeProperty = win.CSSStyleDeclaration.prototype.removeProperty;
	win.CSSStyleDeclaration.prototype.removeProperty = new Proxy(removeProperty, { apply: callbackWrapper((target, thisArg, argumentsList) => {
		const [property] = argumentsList;
		if (ignoreCSSAttributes.has(property)) return removeProperty.apply(thisArg, [property]);
		const { id, styleId } = getIdAndStyleId(thisArg.parentRule?.parentStyleSheet, mirror, stylesheetManager.styleMirror);
		if (id && id !== -1 || styleId && styleId !== -1) styleDeclarationCb({
			id,
			styleId,
			remove: { property },
			index: getNestedCSSRulePositions(thisArg.parentRule)
		});
		return target.apply(thisArg, argumentsList);
	}) });
	return callbackWrapper(() => {
		win.CSSStyleDeclaration.prototype.setProperty = setProperty;
		win.CSSStyleDeclaration.prototype.removeProperty = removeProperty;
	});
}
function initMediaInteractionObserver({ mediaInteractionCb, blockClass, blockSelector, mirror, sampling, doc }) {
	const handler = callbackWrapper((type) => throttle(callbackWrapper((event) => {
		const target = getEventTarget(event);
		if (!target || !(target instanceof HTMLMediaElement) || isBlocked(target, blockClass, blockSelector, true)) return;
		const { currentTime, volume, muted, playbackRate, loop } = target;
		mediaInteractionCb({
			type,
			id: mirror.getId(target),
			currentTime,
			volume,
			muted,
			playbackRate,
			loop
		});
	}), sampling.media || 500));
	const handlers = [
		on("play", handler(MediaInteractions.Play), doc),
		on("pause", handler(MediaInteractions.Pause), doc),
		on("seeked", handler(MediaInteractions.Seeked), doc),
		on("volumechange", handler(MediaInteractions.VolumeChange), doc),
		on("ratechange", handler(MediaInteractions.RateChange), doc)
	];
	return callbackWrapper(() => {
		handlers.forEach((h) => h());
	});
}
function initFontObserver({ fontCb, doc }) {
	const win = doc.defaultView;
	if (!win) return () => {};
	const handlers = [];
	const fontMap = /* @__PURE__ */ new WeakMap();
	const originalFontFace = win.FontFace;
	win.FontFace = function FontFace(family, source, descriptors) {
		const fontFace = new originalFontFace(family, source, descriptors);
		fontMap.set(fontFace, {
			family,
			buffer: typeof source !== "string",
			descriptors,
			fontSource: typeof source === "string" ? source : JSON.stringify(Array.from(new Uint8Array(source)))
		});
		return fontFace;
	};
	const restoreHandler = patch(doc.fonts, "add", function(original) {
		return function(fontFace) {
			setTimeout(callbackWrapper(() => {
				const p = fontMap.get(fontFace);
				if (p) {
					fontCb(p);
					fontMap.delete(fontFace);
				}
			}), 0);
			return original.apply(this, [fontFace]);
		};
	});
	handlers.push(() => {
		win.FontFace = originalFontFace;
	});
	handlers.push(restoreHandler);
	return callbackWrapper(() => {
		handlers.forEach((h) => h());
	});
}
function initSelectionObserver(param) {
	const { doc, mirror, blockClass, blockSelector, selectionCb } = param;
	let collapsed = true;
	const updateSelection = callbackWrapper(() => {
		const selection = doc.getSelection();
		if (!selection || collapsed && selection?.isCollapsed) return;
		collapsed = selection.isCollapsed || false;
		const ranges = [];
		const count = selection.rangeCount || 0;
		for (let i = 0; i < count; i++) {
			const { startContainer, startOffset, endContainer, endOffset } = selection.getRangeAt(i);
			if (isBlocked(startContainer, blockClass, blockSelector, true) || isBlocked(endContainer, blockClass, blockSelector, true)) continue;
			ranges.push({
				start: mirror.getId(startContainer),
				startOffset,
				end: mirror.getId(endContainer),
				endOffset
			});
		}
		selectionCb({ ranges });
	});
	updateSelection();
	return on("selectionchange", updateSelection);
}
function initCustomElementObserver({ doc, customElementCb }) {
	const win = doc.defaultView;
	if (!win || !win.customElements) return () => {};
	return patch(win.customElements, "define", function(original) {
		return function(name, constructor, options) {
			try {
				customElementCb({ define: { name } });
			} catch (e) {
				console.warn(`Custom element callback failed for ${name}`);
			}
			return original.apply(this, [
				name,
				constructor,
				options
			]);
		};
	});
}
function mergeHooks(o, hooks) {
	const { mutationCb, mousemoveCb, mouseInteractionCb, scrollCb, viewportResizeCb, inputCb, mediaInteractionCb, styleSheetRuleCb, styleDeclarationCb, canvasMutationCb, fontCb, selectionCb, customElementCb } = o;
	o.mutationCb = (...p) => {
		if (hooks.mutation) hooks.mutation(...p);
		mutationCb(...p);
	};
	o.mousemoveCb = (...p) => {
		if (hooks.mousemove) hooks.mousemove(...p);
		mousemoveCb(...p);
	};
	o.mouseInteractionCb = (...p) => {
		if (hooks.mouseInteraction) hooks.mouseInteraction(...p);
		mouseInteractionCb(...p);
	};
	o.scrollCb = (...p) => {
		if (hooks.scroll) hooks.scroll(...p);
		scrollCb(...p);
	};
	o.viewportResizeCb = (...p) => {
		if (hooks.viewportResize) hooks.viewportResize(...p);
		viewportResizeCb(...p);
	};
	o.inputCb = (...p) => {
		if (hooks.input) hooks.input(...p);
		inputCb(...p);
	};
	o.mediaInteractionCb = (...p) => {
		if (hooks.mediaInteaction) hooks.mediaInteaction(...p);
		mediaInteractionCb(...p);
	};
	o.styleSheetRuleCb = (...p) => {
		if (hooks.styleSheetRule) hooks.styleSheetRule(...p);
		styleSheetRuleCb(...p);
	};
	o.styleDeclarationCb = (...p) => {
		if (hooks.styleDeclaration) hooks.styleDeclaration(...p);
		styleDeclarationCb(...p);
	};
	o.canvasMutationCb = (...p) => {
		if (hooks.canvasMutation) hooks.canvasMutation(...p);
		canvasMutationCb(...p);
	};
	o.fontCb = (...p) => {
		if (hooks.font) hooks.font(...p);
		fontCb(...p);
	};
	o.selectionCb = (...p) => {
		if (hooks.selection) hooks.selection(...p);
		selectionCb(...p);
	};
	o.customElementCb = (...c) => {
		if (hooks.customElement) hooks.customElement(...c);
		customElementCb(...c);
	};
}
function initObservers(o, hooks = {}) {
	const currentWindow = o.doc.defaultView;
	if (!currentWindow) return () => {};
	mergeHooks(o, hooks);
	let stopMutationObserver;
	if (o.recordDOM) stopMutationObserver = initMutationObserver(o, o.doc);
	const mousemoveHandler = initMoveObserver(o);
	const mouseInteractionHandler = initMouseInteractionObserver(o);
	const scrollHandler = initScrollObserver(o);
	const viewportResizeHandler = initViewportResizeObserver(o, { win: currentWindow });
	const inputHandler = initInputObserver(o);
	const mediaInteractionHandler = initMediaInteractionObserver(o);
	let styleSheetObserver = () => {};
	let adoptedStyleSheetObserver = () => {};
	let styleDeclarationObserver = () => {};
	let fontObserver = () => {};
	if (o.recordDOM) {
		styleSheetObserver = initStyleSheetObserver(o, { win: currentWindow });
		adoptedStyleSheetObserver = initAdoptedStyleSheetObserver(o, o.doc);
		styleDeclarationObserver = initStyleDeclarationObserver(o, { win: currentWindow });
		if (o.collectFonts) fontObserver = initFontObserver(o);
	}
	const selectionObserver = initSelectionObserver(o);
	const customElementObserver = initCustomElementObserver(o);
	const pluginHandlers = [];
	for (const plugin of o.plugins) pluginHandlers.push(plugin.observer(plugin.callback, currentWindow, plugin.options));
	return callbackWrapper(() => {
		stopMutationObserver?.();
		mousemoveHandler();
		mouseInteractionHandler();
		scrollHandler();
		viewportResizeHandler();
		inputHandler();
		mediaInteractionHandler();
		styleSheetObserver();
		adoptedStyleSheetObserver();
		styleDeclarationObserver();
		fontObserver();
		selectionObserver();
		customElementObserver();
		pluginHandlers.forEach((h) => h());
	});
}
function hasNestedCSSRule(prop) {
	return typeof window[prop] !== "undefined";
}
function canMonkeyPatchNestedCSSRule(prop) {
	return Boolean(typeof window[prop] !== "undefined" && window[prop].prototype && "insertRule" in window[prop].prototype && "deleteRule" in window[prop].prototype);
}
// ../rrweb/src/record/cross-origin-iframe-mirror.ts
var CrossOriginIframeMirror = class {
	generateIdFn;
	iframeIdToRemoteIdMap = /* @__PURE__ */ new WeakMap();
	iframeRemoteIdToIdMap = /* @__PURE__ */ new WeakMap();
	constructor(generateIdFn) {
		this.generateIdFn = generateIdFn;
	}
	getId(iframe, remoteId, idToRemoteMap, remoteToIdMap) {
		const idToRemoteIdMap = idToRemoteMap || this.getIdToRemoteIdMap(iframe);
		const remoteIdToIdMap = remoteToIdMap || this.getRemoteIdToIdMap(iframe);
		let id = idToRemoteIdMap.get(remoteId);
		if (!id) {
			id = this.generateIdFn();
			idToRemoteIdMap.set(remoteId, id);
			remoteIdToIdMap.set(id, remoteId);
		}
		return id;
	}
	getIds(iframe, remoteId) {
		const idToRemoteIdMap = this.getIdToRemoteIdMap(iframe);
		const remoteIdToIdMap = this.getRemoteIdToIdMap(iframe);
		return remoteId.map((id) => this.getId(iframe, id, idToRemoteIdMap, remoteIdToIdMap));
	}
	getRemoteId(iframe, id, map) {
		const remoteIdToIdMap = map || this.getRemoteIdToIdMap(iframe);
		if (typeof id !== "number") return id;
		const remoteId = remoteIdToIdMap.get(id);
		if (!remoteId) return -1;
		return remoteId;
	}
	getRemoteIds(iframe, ids) {
		const remoteIdToIdMap = this.getRemoteIdToIdMap(iframe);
		return ids.map((id) => this.getRemoteId(iframe, id, remoteIdToIdMap));
	}
	reset(iframe) {
		if (!iframe) {
			this.iframeIdToRemoteIdMap = /* @__PURE__ */ new WeakMap();
			this.iframeRemoteIdToIdMap = /* @__PURE__ */ new WeakMap();
			return;
		}
		this.iframeIdToRemoteIdMap.delete(iframe);
		this.iframeRemoteIdToIdMap.delete(iframe);
	}
	getIdToRemoteIdMap(iframe) {
		let idToRemoteIdMap = this.iframeIdToRemoteIdMap.get(iframe);
		if (!idToRemoteIdMap) {
			idToRemoteIdMap = /* @__PURE__ */ new Map();
			this.iframeIdToRemoteIdMap.set(iframe, idToRemoteIdMap);
		}
		return idToRemoteIdMap;
	}
	getRemoteIdToIdMap(iframe) {
		let remoteIdToIdMap = this.iframeRemoteIdToIdMap.get(iframe);
		if (!remoteIdToIdMap) {
			remoteIdToIdMap = /* @__PURE__ */ new Map();
			this.iframeRemoteIdToIdMap.set(iframe, remoteIdToIdMap);
		}
		return remoteIdToIdMap;
	}
};
// ../rrweb/src/record/iframe-manager.ts
var IframeManager = class {
	iframes = /* @__PURE__ */ new WeakMap();
	crossOriginIframeMap = /* @__PURE__ */ new WeakMap();
	crossOriginIframeMirror = new CrossOriginIframeMirror(genId);
	crossOriginIframeStyleMirror;
	crossOriginIframeRootIdMap = /* @__PURE__ */ new WeakMap();
	mirror;
	mutationCb;
	wrappedEmit;
	loadListener;
	unloadListener;
	attachedWindows = /* @__PURE__ */ new Map();
	messageHandler = (message) => this.handleMessage(message);
	stylesheetManager;
	recordCrossOriginIframes;
	constructor(options) {
		this.mutationCb = options.mutationCb;
		this.wrappedEmit = options.wrappedEmit;
		this.stylesheetManager = options.stylesheetManager;
		this.recordCrossOriginIframes = options.recordCrossOriginIframes;
		this.crossOriginIframeStyleMirror = new CrossOriginIframeMirror(this.stylesheetManager.styleMirror.generateId.bind(this.stylesheetManager.styleMirror));
		this.mirror = options.mirror;
		if (this.recordCrossOriginIframes) window.addEventListener("message", this.messageHandler);
	}
	addIframe(iframeEl) {
		this.iframes.set(iframeEl, true);
		if (iframeEl.contentWindow) this.crossOriginIframeMap.set(iframeEl.contentWindow, iframeEl);
	}
	addLoadListener(cb) {
		this.loadListener = cb;
	}
	addUnloadListener(cb) {
		this.unloadListener = cb;
	}
	attachIframe(iframeEl, childSn) {
		this.mutationCb({
			adds: [{
				parentId: this.mirror.getId(iframeEl),
				nextId: null,
				node: childSn
			}],
			removes: [],
			texts: [],
			attributes: [],
			isAttachIframe: true
		});
		this.watchIframeWindow(iframeEl);
		this.loadListener?.(iframeEl);
		if (iframeEl.contentDocument && iframeEl.contentDocument.adoptedStyleSheets && iframeEl.contentDocument.adoptedStyleSheets.length > 0) this.stylesheetManager.adoptStyleSheets(iframeEl.contentDocument.adoptedStyleSheets, this.mirror.getId(iframeEl.contentDocument));
	}
	destroy() {
		window.removeEventListener("message", this.messageHandler);
		this.attachedWindows.forEach((stop) => stop());
	}
	watchIframeWindow(iframeEl) {
		const win = iframeEl.contentWindow;
		if (!win || this.attachedWindows.has(win)) return;
		const handlers = [];
		const stop = () => {
			this.attachedWindows.delete(win);
			handlers.forEach((handler) => {
				try {
					handler();
				} catch {}
			});
		};
		this.attachedWindows.set(win, stop);
		if (this.recordCrossOriginIframes) handlers.push(on("message", this.messageHandler, win));
		handlers.push(on("pagehide", (event) => {
			if (event.persisted) return;
			const doc = win.document;
			stop();
			this.unloadListener?.(doc);
		}, win));
	}
	handleMessage(message) {
		const crossOriginMessageEvent = message;
		if (crossOriginMessageEvent.data.type !== "rrweb" || crossOriginMessageEvent.origin !== crossOriginMessageEvent.data.origin) return;
		if (!message.source) return;
		const iframeEl = this.crossOriginIframeMap.get(message.source);
		if (!iframeEl) return;
		const transformedEvent = this.transformCrossOriginEvent(iframeEl, crossOriginMessageEvent.data.event);
		if (transformedEvent) this.wrappedEmit(transformedEvent, crossOriginMessageEvent.data.isCheckout);
	}
	transformCrossOriginEvent(iframeEl, e) {
		switch (e.type) {
			case EventType.FullSnapshot: {
				this.crossOriginIframeMirror.reset(iframeEl);
				this.crossOriginIframeStyleMirror.reset(iframeEl);
				/**
				* Replaces the original id of the iframe with a new set of unique ids
				*/
				this.replaceIdOnNode(e.data.node, iframeEl);
				const rootId = e.data.node.id;
				this.crossOriginIframeRootIdMap.set(iframeEl, rootId);
				this.patchRootIdOnNode(e.data.node, rootId);
				return {
					timestamp: e.timestamp,
					type: EventType.IncrementalSnapshot,
					data: {
						source: IncrementalSource.Mutation,
						adds: [{
							parentId: this.mirror.getId(iframeEl),
							nextId: null,
							node: e.data.node
						}],
						removes: [],
						texts: [],
						attributes: [],
						isAttachIframe: true
					}
				};
			}
			case EventType.Meta:
			case EventType.Load:
			case EventType.DomContentLoaded: return false;
			case EventType.Annotation:
			case EventType.Plugin: return e;
			case EventType.Custom:
				this.replaceIds(e.data.payload, iframeEl, [
					"id",
					"parentId",
					"previousId",
					"nextId"
				]);
				return e;
			case EventType.IncrementalSnapshot: switch (e.data.source) {
				case IncrementalSource.Mutation:
					e.data.adds.forEach((n) => {
						this.replaceIds(n, iframeEl, [
							"parentId",
							"nextId",
							"previousId"
						]);
						this.replaceIdOnNode(n.node, iframeEl);
						const rootId = this.crossOriginIframeRootIdMap.get(iframeEl);
						rootId && this.patchRootIdOnNode(n.node, rootId);
					});
					e.data.removes.forEach((n) => {
						this.replaceIds(n, iframeEl, ["parentId", "id"]);
					});
					e.data.attributes.forEach((n) => {
						this.replaceIds(n, iframeEl, ["id"]);
					});
					e.data.texts.forEach((n) => {
						this.replaceIds(n, iframeEl, ["id"]);
					});
					return e;
				case IncrementalSource.Drag:
				case IncrementalSource.TouchMove:
				case IncrementalSource.MouseMove:
					e.data.positions.forEach((p) => {
						this.replaceIds(p, iframeEl, ["id"]);
					});
					return e;
				case IncrementalSource.ViewportResize: return false;
				case IncrementalSource.MediaInteraction:
				case IncrementalSource.MouseInteraction:
				case IncrementalSource.Scroll:
				case IncrementalSource.CanvasMutation:
				case IncrementalSource.Input:
					this.replaceIds(e.data, iframeEl, ["id"]);
					return e;
				case IncrementalSource.StyleSheetRule:
				case IncrementalSource.StyleDeclaration:
					this.replaceIds(e.data, iframeEl, ["id"]);
					this.replaceStyleIds(e.data, iframeEl, ["styleId"]);
					return e;
				case IncrementalSource.Font: return e;
				case IncrementalSource.Selection:
					e.data.ranges.forEach((range) => {
						this.replaceIds(range, iframeEl, ["start", "end"]);
					});
					return e;
				case IncrementalSource.AdoptedStyleSheet:
					this.replaceIds(e.data, iframeEl, ["id"]);
					this.replaceStyleIds(e.data, iframeEl, ["styleIds"]);
					e.data.styles?.forEach((style) => {
						this.replaceStyleIds(style, iframeEl, ["styleId"]);
					});
					return e;
			}
		}
		return false;
	}
	replace(iframeMirror, obj, iframeEl, keys) {
		for (const key of keys) {
			if (!Array.isArray(obj[key]) && typeof obj[key] !== "number") continue;
			if (Array.isArray(obj[key])) obj[key] = iframeMirror.getIds(iframeEl, obj[key]);
			else obj[key] = iframeMirror.getId(iframeEl, obj[key]);
		}
		return obj;
	}
	replaceIds(obj, iframeEl, keys) {
		return this.replace(this.crossOriginIframeMirror, obj, iframeEl, keys);
	}
	replaceStyleIds(obj, iframeEl, keys) {
		return this.replace(this.crossOriginIframeStyleMirror, obj, iframeEl, keys);
	}
	replaceIdOnNode(node, iframeEl) {
		this.replaceIds(node, iframeEl, ["id", "rootId"]);
		if ("childNodes" in node) node.childNodes.forEach((child) => {
			this.replaceIdOnNode(child, iframeEl);
		});
	}
	patchRootIdOnNode(node, rootId) {
		if (node.type !== NodeType.Document && !node.rootId) node.rootId = rootId;
		if ("childNodes" in node) node.childNodes.forEach((child) => {
			this.patchRootIdOnNode(child, rootId);
		});
	}
};
// ../rrweb/src/record/shadow-dom-manager.ts
var ShadowDomManager = class {
	/** Observed shadow roots and the handlers that stop observing them. */
	shadowDoms = /* @__PURE__ */ new Map();
	mutationCb;
	scrollCb;
	bypassOptions;
	mirror;
	restoreHandlers = [];
	constructor(options) {
		this.mutationCb = options.mutationCb;
		this.scrollCb = options.scrollCb;
		this.bypassOptions = options.bypassOptions;
		this.mirror = options.mirror;
		this.init();
	}
	init() {
		this.reset();
		this.patchAttachShadow(Element, document);
	}
	addShadowRoot(shadowRoot, doc) {
		if (!isNativeShadowDom(shadowRoot)) return;
		if (this.shadowDoms.has(shadowRoot)) return;
		const handlers = [];
		this.shadowDoms.set(shadowRoot, handlers);
		const stopMutationObserver = initMutationObserver({
			...this.bypassOptions,
			doc,
			mutationCb: this.mutationCb,
			mirror: this.mirror,
			shadowDomManager: this
		}, shadowRoot);
		handlers.push(stopMutationObserver);
		handlers.push(initScrollObserver({
			...this.bypassOptions,
			scrollCb: this.scrollCb,
			doc: shadowRoot,
			mirror: this.mirror
		}));
		setTimeout(() => {
			if (this.shadowDoms.get(shadowRoot) !== handlers) return;
			if (shadowRoot.adoptedStyleSheets && shadowRoot.adoptedStyleSheets.length > 0) this.bypassOptions.stylesheetManager.adoptStyleSheets(shadowRoot.adoptedStyleSheets, this.mirror.getId(src_default.host(shadowRoot)));
			handlers.push(initAdoptedStyleSheetObserver({
				mirror: this.mirror,
				stylesheetManager: this.bypassOptions.stylesheetManager
			}, shadowRoot));
		}, 0);
	}
	removeShadowRootsIn(n) {
		if (this.shadowDoms.size === 0) return;
		const shadowRoot = src_default.shadowRoot(n);
		if (shadowRoot) {
			if (this.shadowDoms.has(shadowRoot)) this.removeShadowRoot(shadowRoot);
			this.removeShadowRootsIn(shadowRoot);
		}
		src_default.childNodes(n).forEach((child) => this.removeShadowRootsIn(child));
	}
	removeShadowRoot(shadowRoot) {
		const handlers = this.shadowDoms.get(shadowRoot);
		this.shadowDoms.delete(shadowRoot);
		handlers?.forEach(runHandler);
	}
	/**
	* Monkey patch 'attachShadow' of an IFrameElement to observe newly added shadow doms.
	*/
	observeAttachShadow(iframeElement) {
		if (!iframeElement.contentWindow || !iframeElement.contentDocument) return;
		this.patchAttachShadow(iframeElement.contentWindow.Element, iframeElement.contentDocument);
	}
	/**
	* Patch 'attachShadow' to observe newly added shadow doms.
	*/
	patchAttachShadow(element, doc) {
		const manager = this;
		this.restoreHandlers.push(patch(element.prototype, "attachShadow", function(original) {
			return function(option) {
				const sRoot = original.call(this, option);
				const shadowRootEl = src_default.shadowRoot(this);
				if (shadowRootEl && inDom(this)) manager.addShadowRoot(shadowRootEl, doc);
				return sRoot;
			};
		}));
	}
	reset() {
		this.restoreHandlers.forEach(runHandler);
		this.restoreHandlers = [];
		const shadowDoms = this.shadowDoms;
		this.shadowDoms = /* @__PURE__ */ new Map();
		shadowDoms.forEach((handlers) => handlers.forEach(runHandler));
	}
};
function runHandler(handler) {
	try {
		handler();
	} catch (e) {}
}
// ../../node_modules/base64-arraybuffer/dist/base64-arraybuffer.es5.js
var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
var lookup = typeof Uint8Array === "undefined" ? [] : /* @__PURE__ */ new Uint8Array(256);
for (var i = 0; i < chars.length; i++) lookup[chars.charCodeAt(i)] = i;
var encode = function(arraybuffer) {
	var bytes = new Uint8Array(arraybuffer), i, len = bytes.length, base64 = "";
	for (i = 0; i < len; i += 3) {
		base64 += chars[bytes[i] >> 2];
		base64 += chars[(bytes[i] & 3) << 4 | bytes[i + 1] >> 4];
		base64 += chars[(bytes[i + 1] & 15) << 2 | bytes[i + 2] >> 6];
		base64 += chars[bytes[i + 2] & 63];
	}
	if (len % 3 === 2) base64 = base64.substring(0, base64.length - 1) + "=";
	else if (len % 3 === 1) base64 = base64.substring(0, base64.length - 2) + "==";
	return base64;
};
// ../rrweb/src/record/observers/canvas/serialize-args.ts
var canvasVarMap = /* @__PURE__ */ new Map();
function variableListFor(ctx, ctor) {
	let contextMap = canvasVarMap.get(ctx);
	if (!contextMap) {
		contextMap = /* @__PURE__ */ new Map();
		canvasVarMap.set(ctx, contextMap);
	}
	if (!contextMap.has(ctor)) contextMap.set(ctor, []);
	return contextMap.get(ctor);
}
var saveWebGLVar = (value, win, ctx) => {
	if (!value || !(isInstanceOfWebGLObject(value, win) || typeof value === "object")) return;
	const name = value.constructor.name;
	const list = variableListFor(ctx, name);
	let index = list.indexOf(value);
	if (index === -1) {
		index = list.length;
		list.push(value);
	}
	return index;
};
function serializeArg(value, win, ctx) {
	if (value instanceof Array) return value.map((arg) => serializeArg(arg, win, ctx));
	else if (value === null) return value;
	else if (value instanceof Float32Array || value instanceof Float64Array || value instanceof Int32Array || value instanceof Uint32Array || value instanceof Uint8Array || value instanceof Uint16Array || value instanceof Int16Array || value instanceof Int8Array || value instanceof Uint8ClampedArray) return {
		rr_type: value.constructor.name,
		args: [Object.values(value)]
	};
	else if (value instanceof ArrayBuffer) return {
		rr_type: value.constructor.name,
		base64: encode(value)
	};
	else if (value instanceof DataView) return {
		rr_type: value.constructor.name,
		args: [
			serializeArg(value.buffer, win, ctx),
			value.byteOffset,
			value.byteLength
		]
	};
	else if (value instanceof HTMLImageElement) {
		const name = value.constructor.name;
		const { src } = value;
		return {
			rr_type: name,
			src
		};
	} else if (value instanceof HTMLCanvasElement) return {
		rr_type: "HTMLImageElement",
		src: value.toDataURL()
	};
	else if (value instanceof ImageData) return {
		rr_type: value.constructor.name,
		args: [
			serializeArg(value.data, win, ctx),
			value.width,
			value.height
		]
	};
	else if (isInstanceOfWebGLObject(value, win) || typeof value === "object") return {
		rr_type: value.constructor.name,
		index: saveWebGLVar(value, win, ctx)
	};
	return value;
}
var serializeArgs = (args, win, ctx) => {
	return args.map((arg) => serializeArg(arg, win, ctx));
};
var isInstanceOfWebGLObject = (value, win) => {
	const supportedWebGLConstructorNames = [
		"WebGLActiveInfo",
		"WebGLBuffer",
		"WebGLFramebuffer",
		"WebGLProgram",
		"WebGLRenderbuffer",
		"WebGLShader",
		"WebGLShaderPrecisionFormat",
		"WebGLTexture",
		"WebGLUniformLocation",
		"WebGLVertexArrayObject",
		"WebGLVertexArrayObjectOES"
	].filter((name) => typeof win[name] === "function");
	return Boolean(supportedWebGLConstructorNames.find((name) => value instanceof win[name]));
};
// ../rrweb/src/record/observers/canvas/2d.ts
function initCanvas2DMutationObserver(cb, win, blockClass, blockSelector) {
	const handlers = [];
	const props2D = Object.getOwnPropertyNames(win.CanvasRenderingContext2D.prototype);
	for (const prop of props2D) try {
		if (typeof win.CanvasRenderingContext2D.prototype[prop] !== "function") continue;
		const restoreHandler = patch(win.CanvasRenderingContext2D.prototype, prop, function(original) {
			return function(...args) {
				if (!isBlocked(this.canvas, blockClass, blockSelector, true)) setTimeout(() => {
					const recordArgs = serializeArgs(args, win, this);
					cb(this.canvas, {
						type: CanvasContext["2D"],
						property: prop,
						args: recordArgs
					});
				}, 0);
				return original.apply(this, args);
			};
		});
		handlers.push(restoreHandler);
	} catch {
		const hookHandler = hookSetter(win.CanvasRenderingContext2D.prototype, prop, { set(v) {
			cb(this.canvas, {
				type: CanvasContext["2D"],
				property: prop,
				args: [v],
				setter: true
			});
		} });
		handlers.push(hookHandler);
	}
	return () => {
		handlers.forEach((h) => h());
	};
}
// ../rrweb/src/record/observers/canvas/canvas.ts
function getNormalizedContextName(contextType) {
	return contextType === "experimental-webgl" ? "webgl" : contextType;
}
function initCanvasContextObserver(win, blockClass, blockSelector, setPreserveDrawingBufferToTrue) {
	const handlers = [];
	try {
		const restoreHandler = patch(win.HTMLCanvasElement.prototype, "getContext", function(original) {
			return function(contextType, ...args) {
				if (!isBlocked(this, blockClass, blockSelector, true)) {
					const ctxName = getNormalizedContextName(contextType);
					if (!("__context" in this)) this.__context = ctxName;
					if (setPreserveDrawingBufferToTrue && ["webgl", "webgl2"].includes(ctxName)) {
						if (args[0] && typeof args[0] === "object") {
							const contextAttributes = args[0];
							if (!contextAttributes.preserveDrawingBuffer) contextAttributes.preserveDrawingBuffer = true;
						} else args.splice(0, 1, { preserveDrawingBuffer: true });
					}
				}
				return original.apply(this, [contextType, ...args]);
			};
		});
		handlers.push(restoreHandler);
	} catch {
		console.error("failed to patch HTMLCanvasElement.prototype.getContext");
	}
	return () => {
		handlers.forEach((h) => h());
	};
}
// ../rrweb/src/record/observers/canvas/webgl.ts
function patchGLPrototype(prototype, type, cb, blockClass, blockSelector, win) {
	const handlers = [];
	const props = Object.getOwnPropertyNames(prototype);
	for (const prop of props) {
		if ([
			"isContextLost",
			"canvas",
			"drawingBufferWidth",
			"drawingBufferHeight"
		].includes(prop)) continue;
		try {
			if (typeof prototype[prop] !== "function") continue;
			const restoreHandler = patch(prototype, prop, function(original) {
				return function(...args) {
					const result = original.apply(this, args);
					saveWebGLVar(result, win, this);
					if ("tagName" in this.canvas && !isBlocked(this.canvas, blockClass, blockSelector, true)) {
						const recordArgs = serializeArgs(args, win, this);
						const mutation = {
							type,
							property: prop,
							args: recordArgs
						};
						cb(this.canvas, mutation);
					}
					return result;
				};
			});
			handlers.push(restoreHandler);
		} catch {
			const hookHandler = hookSetter(prototype, prop, { set(v) {
				cb(this.canvas, {
					type,
					property: prop,
					args: [v],
					setter: true
				});
			} });
			handlers.push(hookHandler);
		}
	}
	return handlers;
}
function initCanvasWebGLMutationObserver(cb, win, blockClass, blockSelector) {
	const handlers = [];
	if (typeof win.WebGLRenderingContext !== "undefined") handlers.push(...patchGLPrototype(win.WebGLRenderingContext.prototype, CanvasContext.WebGL, cb, blockClass, blockSelector, win));
	if (typeof win.WebGL2RenderingContext !== "undefined") handlers.push(...patchGLPrototype(win.WebGL2RenderingContext.prototype, CanvasContext.WebGL2, cb, blockClass, blockSelector, win));
	return () => {
		handlers.forEach((h) => h());
	};
}
// ../rrweb/src/record/workers/image-bitmap-data-url-worker.ts?worker&inline
var jsContent = "(function() {\n	// ../../node_modules/base64-arraybuffer/dist/base64-arraybuffer.es5.js\n	var chars = \"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\";\n	var lookup = typeof Uint8Array === \"undefined\" ? [] : /* @__PURE__ */ new Uint8Array(256);\n	for (var i = 0; i < chars.length; i++) lookup[chars.charCodeAt(i)] = i;\n	var encode = function(arraybuffer) {\n		var bytes = new Uint8Array(arraybuffer), i, len = bytes.length, base64 = \"\";\n		for (i = 0; i < len; i += 3) {\n			base64 += chars[bytes[i] >> 2];\n			base64 += chars[(bytes[i] & 3) << 4 | bytes[i + 1] >> 4];\n			base64 += chars[(bytes[i + 1] & 15) << 2 | bytes[i + 2] >> 6];\n			base64 += chars[bytes[i + 2] & 63];\n		}\n		if (len % 3 === 2) base64 = base64.substring(0, base64.length - 1) + \"=\";\n		else if (len % 3 === 1) base64 = base64.substring(0, base64.length - 2) + \"==\";\n		return base64;\n	};\n	// ../rrweb/src/record/workers/image-bitmap-data-url-worker.ts\n	const lastBlobMap = /* @__PURE__ */ new Map();\n	const transparentBlobMap = /* @__PURE__ */ new Map();\n	async function getTransparentBlobFor(width, height, dataURLOptions) {\n		const id = `${width}-${height}`;\n		if (\"OffscreenCanvas\" in globalThis) {\n			if (transparentBlobMap.has(id)) return transparentBlobMap.get(id);\n			const offscreen = new OffscreenCanvas(width, height);\n			offscreen.getContext(\"2d\");\n			const base64 = encode(await (await offscreen.convertToBlob(dataURLOptions)).arrayBuffer());\n			transparentBlobMap.set(id, base64);\n			return base64;\n		} else return \"\";\n	}\n	const worker = self;\n	worker.onmessage = async function(e) {\n		if (\"OffscreenCanvas\" in globalThis) {\n			const { id, bitmap, width, height, dataURLOptions } = e.data;\n			const transparentBase64 = getTransparentBlobFor(width, height, dataURLOptions);\n			const offscreen = new OffscreenCanvas(width, height);\n			offscreen.getContext(\"2d\").drawImage(bitmap, 0, 0);\n			bitmap.close();\n			const blob = await offscreen.convertToBlob(dataURLOptions);\n			const type = blob.type;\n			const base64 = encode(await blob.arrayBuffer());\n			if (!lastBlobMap.has(id) && await transparentBase64 === base64) {\n				lastBlobMap.set(id, base64);\n				return worker.postMessage({ id });\n			}\n			if (lastBlobMap.get(id) === base64) return worker.postMessage({ id });\n			worker.postMessage({\n				id,\n				type,\n				base64,\n				width,\n				height\n			});\n			lastBlobMap.set(id, base64);\n		} else return worker.postMessage({ id: e.data.id });\n	};\n})();\n\n//# sourceMappingURL=image-bitmap-data-url-worker-DVcMqE1_.js.map";
var blob = typeof self !== "undefined" && self.Blob && new Blob(["(self.URL || self.webkitURL).revokeObjectURL(self.location.href);", jsContent], { type: "text/javascript;charset=utf-8" });
function WorkerWrapper(options) {
	let objURL;
	try {
		objURL = blob && (self.URL || self.webkitURL).createObjectURL(blob);
		if (!objURL) throw "";
		const worker = new Worker(objURL, { name: options?.name });
		worker.addEventListener("error", () => {
			(self.URL || self.webkitURL).revokeObjectURL(objURL);
		});
		return worker;
	} catch (e) {
		return new Worker("data:text/javascript;charset=utf-8," + encodeURIComponent(jsContent), { name: options?.name });
	}
}
// ../rrweb/src/record/observers/canvas/canvas-manager.ts
var CanvasManager = class {
	pendingCanvasMutations = /* @__PURE__ */ new Map();
	rafStamps = {
		latestId: 0,
		invokeId: null
	};
	mirror;
	mutationCb;
	resetObservers;
	frozen = false;
	locked = false;
	reset() {
		this.pendingCanvasMutations.clear();
		this.resetObservers && this.resetObservers();
	}
	freeze() {
		this.frozen = true;
	}
	unfreeze() {
		this.frozen = false;
	}
	lock() {
		this.locked = true;
	}
	unlock() {
		this.locked = false;
	}
	constructor(options) {
		const { sampling = "all", win, blockClass, blockSelector, recordCanvas, dataURLOptions } = options;
		this.mutationCb = options.mutationCb;
		this.mirror = options.mirror;
		if (recordCanvas && sampling === "all") this.initCanvasMutationObserver(win, blockClass, blockSelector);
		if (recordCanvas && typeof sampling === "number") this.initCanvasFPSObserver(sampling, win, blockClass, blockSelector, { dataURLOptions });
	}
	processMutation = (target, mutation) => {
		if (this.rafStamps.invokeId && this.rafStamps.latestId !== this.rafStamps.invokeId || !this.rafStamps.invokeId) this.rafStamps.invokeId = this.rafStamps.latestId;
		if (!this.pendingCanvasMutations.has(target)) this.pendingCanvasMutations.set(target, []);
		this.pendingCanvasMutations.get(target).push(mutation);
	};
	initCanvasFPSObserver(fps, win, blockClass, blockSelector, options) {
		const canvasContextReset = initCanvasContextObserver(win, blockClass, blockSelector, true);
		const snapshotInProgressMap = /* @__PURE__ */ new Map();
		const worker = new WorkerWrapper();
		worker.onmessage = (e) => {
			const { id } = e.data;
			snapshotInProgressMap.set(id, false);
			if (!("base64" in e.data)) return;
			const { base64, type, width, height } = e.data;
			this.mutationCb({
				id,
				type: CanvasContext["2D"],
				commands: [{
					property: "clearRect",
					args: [
						0,
						0,
						width,
						height
					]
				}, {
					property: "drawImage",
					args: [
						{
							rr_type: "ImageBitmap",
							args: [{
								rr_type: "Blob",
								data: [{
									rr_type: "ArrayBuffer",
									base64
								}],
								type
							}]
						},
						0,
						0
					]
				}]
			});
		};
		const timeBetweenSnapshots = 1e3 / fps;
		let lastSnapshotTime = 0;
		let rafId;
		const getCanvas = () => {
			const matchedCanvas = [];
			win.document.querySelectorAll("canvas").forEach((canvas) => {
				if (!isBlocked(canvas, blockClass, blockSelector, true)) matchedCanvas.push(canvas);
			});
			return matchedCanvas;
		};
		const takeCanvasSnapshots = (timestamp) => {
			if (lastSnapshotTime && timestamp - lastSnapshotTime < timeBetweenSnapshots) {
				rafId = requestAnimationFrame(takeCanvasSnapshots);
				return;
			}
			lastSnapshotTime = timestamp;
			getCanvas().forEach(async (canvas) => {
				const id = this.mirror.getId(canvas);
				if (snapshotInProgressMap.get(id)) return;
				if (canvas.width === 0 || canvas.height === 0) return;
				snapshotInProgressMap.set(id, true);
				if (["webgl", "webgl2"].includes(canvas.__context)) {
					const context = canvas.getContext(canvas.__context);
					if (context?.getContextAttributes()?.preserveDrawingBuffer === false) context.clear(context.COLOR_BUFFER_BIT);
				}
				const bitmap = await createImageBitmap(canvas);
				worker.postMessage({
					id,
					bitmap,
					width: canvas.width,
					height: canvas.height,
					dataURLOptions: options.dataURLOptions
				}, [bitmap]);
			});
			rafId = requestAnimationFrame(takeCanvasSnapshots);
		};
		rafId = requestAnimationFrame(takeCanvasSnapshots);
		this.resetObservers = () => {
			canvasContextReset();
			cancelAnimationFrame(rafId);
		};
	}
	initCanvasMutationObserver(win, blockClass, blockSelector) {
		this.startRAFTimestamping();
		this.startPendingCanvasMutationFlusher();
		const canvasContextReset = initCanvasContextObserver(win, blockClass, blockSelector, false);
		const canvas2DReset = initCanvas2DMutationObserver(this.processMutation.bind(this), win, blockClass, blockSelector);
		const canvasWebGL1and2Reset = initCanvasWebGLMutationObserver(this.processMutation.bind(this), win, blockClass, blockSelector);
		this.resetObservers = () => {
			canvasContextReset();
			canvas2DReset();
			canvasWebGL1and2Reset();
		};
	}
	startPendingCanvasMutationFlusher() {
		requestAnimationFrame(() => this.flushPendingCanvasMutations());
	}
	startRAFTimestamping() {
		const setLatestRAFTimestamp = (timestamp) => {
			this.rafStamps.latestId = timestamp;
			requestAnimationFrame(setLatestRAFTimestamp);
		};
		requestAnimationFrame(setLatestRAFTimestamp);
	}
	flushPendingCanvasMutations() {
		this.pendingCanvasMutations.forEach((_values, canvas) => {
			const id = this.mirror.getId(canvas);
			this.flushPendingCanvasMutationFor(canvas, id);
		});
		requestAnimationFrame(() => this.flushPendingCanvasMutations());
	}
	flushPendingCanvasMutationFor(canvas, id) {
		if (this.frozen || this.locked) return;
		const valuesWithType = this.pendingCanvasMutations.get(canvas);
		if (!valuesWithType || id === -1) return;
		const values = valuesWithType.map((value) => {
			const { type, ...rest } = value;
			return rest;
		});
		const { type } = valuesWithType[0];
		this.mutationCb({
			id,
			type,
			commands: values
		});
		this.pendingCanvasMutations.delete(canvas);
	}
};
// ../rrweb/src/record/stylesheet-manager.ts
var StylesheetManager = class {
	trackedLinkElements = /* @__PURE__ */ new WeakSet();
	mutationCb;
	adoptedStyleSheetCb;
	styleMirror = new StyleSheetMirror();
	constructor(options) {
		this.mutationCb = options.mutationCb;
		this.adoptedStyleSheetCb = options.adoptedStyleSheetCb;
	}
	attachLinkElement(linkEl, childSn) {
		if ("_cssText" in childSn.attributes) this.mutationCb({
			adds: [],
			removes: [],
			texts: [],
			attributes: [{
				id: childSn.id,
				attributes: childSn.attributes
			}]
		});
		this.trackLinkElement(linkEl);
	}
	trackLinkElement(linkEl) {
		if (this.trackedLinkElements.has(linkEl)) return;
		this.trackedLinkElements.add(linkEl);
		this.trackStylesheetInLinkElement(linkEl);
	}
	adoptStyleSheets(sheets, hostId) {
		if (sheets.length === 0) return;
		const adoptedStyleSheetData = {
			id: hostId,
			styleIds: []
		};
		const styles = [];
		for (const sheet of sheets) {
			let styleId;
			if (!this.styleMirror.has(sheet)) {
				styleId = this.styleMirror.add(sheet);
				styles.push({
					styleId,
					rules: Array.from(sheet.rules || CSSRule, (r, index) => ({
						rule: stringifyRule(r, sheet.href),
						index
					}))
				});
			} else styleId = this.styleMirror.getId(sheet);
			adoptedStyleSheetData.styleIds.push(styleId);
		}
		if (styles.length > 0) adoptedStyleSheetData.styles = styles;
		this.adoptedStyleSheetCb(adoptedStyleSheetData);
	}
	reset() {
		this.styleMirror.reset();
		this.trackedLinkElements = /* @__PURE__ */ new WeakSet();
	}
	trackStylesheetInLinkElement(_linkEl) {}
};
// ../rrweb/src/record/processed-node-manager.ts
/**
* Keeps a log of nodes that could show up in multiple mutation buffer but shouldn't be handled twice.
*/
var ProcessedNodeManager = class {
	nodeMap = /* @__PURE__ */ new WeakMap();
	active = false;
	inOtherBuffer(node, thisBuffer) {
		const buffers = this.nodeMap.get(node);
		return buffers && Array.from(buffers).some((buffer) => buffer !== thisBuffer);
	}
	add(node, buffer) {
		if (!this.active) {
			this.active = true;
			requestAnimationFrame(() => {
				this.nodeMap = /* @__PURE__ */ new WeakMap();
				this.active = false;
			});
		}
		this.nodeMap.set(node, (this.nodeMap.get(node) || /* @__PURE__ */ new Set()).add(buffer));
	}
	destroy() {}
};
// ../rrweb/src/record/index.ts
var wrappedEmit;
var takeFullSnapshot;
var canvasManager;
var recording = false;
try {
	if (Array.from([1], (x) => x * 2)[0] !== 2) {
		const cleanFrame = document.createElement("iframe");
		document.body.appendChild(cleanFrame);
		Array.from = cleanFrame.contentWindow?.Array.from || Array.from;
		document.body.removeChild(cleanFrame);
	}
} catch (err) {
	console.debug("Unable to override Array.from", err);
}
var mirror = createMirror();
function record(options = {}) {
	const { emit, checkoutEveryNms, checkoutEveryNth, blockClass = "rr-block", blockSelector = null, ignoreClass = "rr-ignore", ignoreSelector = null, maskTextClass = "rr-mask", maskTextSelector = null, inlineStylesheet = true, maskAllInputs, maskInputOptions: _maskInputOptions, slimDOMOptions: _slimDOMOptions, maskInputFn, maskTextFn, hooks, packFn, sampling = {}, dataURLOptions = {}, mousemoveWait, recordDOM = true, recordCanvas = false, recordCrossOriginIframes = false, recordAfter = options.recordAfter === "DOMContentLoaded" ? options.recordAfter : "load", userTriggeredOnInput = false, collectFonts = false, inlineImages = false, plugins, keepIframeSrcFn = () => false, ignoreCSSAttributes = /* @__PURE__ */ new Set([]), errorHandler } = options;
	registerErrorHandler(errorHandler);
	const inEmittingFrame = recordCrossOriginIframes ? window.parent === window : true;
	let passEmitsToParent = false;
	if (!inEmittingFrame) try {
		if (window.parent.document) passEmitsToParent = false;
	} catch (e) {
		passEmitsToParent = true;
	}
	if (inEmittingFrame && !emit) throw new Error("emit function is required");
	if (!inEmittingFrame && !passEmitsToParent) return () => {};
	if (mousemoveWait !== void 0 && sampling.mousemove === void 0) sampling.mousemove = mousemoveWait;
	mirror.reset();
	const maskInputOptions = maskAllInputs === true ? {
		color: true,
		date: true,
		"datetime-local": true,
		email: true,
		month: true,
		number: true,
		range: true,
		search: true,
		tel: true,
		text: true,
		time: true,
		url: true,
		week: true,
		textarea: true,
		select: true,
		password: true
	} : _maskInputOptions !== void 0 ? _maskInputOptions : { password: true };
	const slimDOMOptions = slimDOMDefaults(_slimDOMOptions);
	polyfill();
	let lastFullSnapshotEvent;
	let incrementalSnapshotCount = 0;
	const eventProcessor = (e) => {
		for (const plugin of plugins || []) if (plugin.eventProcessor) e = plugin.eventProcessor(e);
		if (packFn && !passEmitsToParent) e = packFn(e);
		return e;
	};
	wrappedEmit = (r, isCheckout) => {
		const e = r;
		e.timestamp = nowTimestamp();
		if (e.type !== EventType.FullSnapshot && !(e.type === EventType.IncrementalSnapshot && e.data.source === IncrementalSource.Mutation)) {
			canvasManager.unfreeze();
			for (const buf of mutationBuffers) if (buf.isFrozen()) buf.unfreeze();
			else break;
		}
		if (inEmittingFrame) emit?.(eventProcessor(e), isCheckout);
		else if (passEmitsToParent) {
			const message = {
				type: "rrweb",
				event: eventProcessor(e),
				origin: window.location.origin,
				isCheckout
			};
			window.parent.postMessage(message, "*");
		}
		if (e.type === EventType.FullSnapshot) {
			lastFullSnapshotEvent = e;
			incrementalSnapshotCount = 0;
		} else if (e.type === EventType.IncrementalSnapshot) {
			if (e.data.source === IncrementalSource.Mutation && e.data.isAttachIframe) return;
			incrementalSnapshotCount++;
			const exceedCount = checkoutEveryNth && incrementalSnapshotCount >= checkoutEveryNth;
			const exceedTime = checkoutEveryNms && e.timestamp - lastFullSnapshotEvent.timestamp > checkoutEveryNms;
			if (exceedCount || exceedTime) takeFullSnapshot(true);
		}
	};
	const wrappedMutationEmit = (m) => {
		wrappedEmit({
			type: EventType.IncrementalSnapshot,
			data: {
				source: IncrementalSource.Mutation,
				...m
			}
		});
	};
	const wrappedScrollEmit = (p) => wrappedEmit({
		type: EventType.IncrementalSnapshot,
		data: {
			source: IncrementalSource.Scroll,
			...p
		}
	});
	const wrappedCanvasMutationEmit = (p) => wrappedEmit({
		type: EventType.IncrementalSnapshot,
		data: {
			source: IncrementalSource.CanvasMutation,
			...p
		}
	});
	const wrappedAdoptedStyleSheetEmit = (a) => wrappedEmit({
		type: EventType.IncrementalSnapshot,
		data: {
			source: IncrementalSource.AdoptedStyleSheet,
			...a
		}
	});
	const stylesheetManager = new StylesheetManager({
		mutationCb: wrappedMutationEmit,
		adoptedStyleSheetCb: wrappedAdoptedStyleSheetEmit
	});
	const iframeManager = new IframeManager({
		mirror,
		mutationCb: wrappedMutationEmit,
		stylesheetManager,
		recordCrossOriginIframes,
		wrappedEmit
	});
	/**
	* Exposes mirror to the plugins
	*/
	for (const plugin of plugins || []) if (plugin.getMirror) plugin.getMirror({
		nodeMirror: mirror,
		crossOriginIframeMirror: iframeManager.crossOriginIframeMirror,
		crossOriginIframeStyleMirror: iframeManager.crossOriginIframeStyleMirror
	});
	const processedNodeManager = new ProcessedNodeManager();
	canvasManager = new CanvasManager({
		recordCanvas,
		mutationCb: wrappedCanvasMutationEmit,
		win: window,
		blockClass,
		blockSelector,
		mirror,
		sampling: sampling.canvas,
		dataURLOptions
	});
	const shadowDomManager = new ShadowDomManager({
		mutationCb: wrappedMutationEmit,
		scrollCb: wrappedScrollEmit,
		bypassOptions: {
			blockClass,
			blockSelector,
			maskTextClass,
			maskTextSelector,
			inlineStylesheet,
			maskInputOptions,
			dataURLOptions,
			maskTextFn,
			maskInputFn,
			recordCanvas,
			inlineImages,
			sampling,
			slimDOMOptions,
			iframeManager,
			stylesheetManager,
			canvasManager,
			keepIframeSrcFn,
			processedNodeManager
		},
		mirror
	});
	takeFullSnapshot = (isCheckout = false) => {
		if (!recordDOM) return;
		wrappedEmit({
			type: EventType.Meta,
			data: {
				href: window.location.href,
				width: getWindowWidth(),
				height: getWindowHeight()
			}
		}, isCheckout);
		stylesheetManager.reset();
		shadowDomManager.init();
		canvasManager.lock();
		mutationBuffers.forEach((buf) => buf.lock());
		const node = snapshot(document, {
			mirror,
			blockClass,
			blockSelector,
			maskTextClass,
			maskTextSelector,
			inlineStylesheet,
			maskAllInputs: maskInputOptions,
			maskTextFn,
			maskInputFn,
			slimDOM: slimDOMOptions,
			dataURLOptions,
			recordCanvas,
			inlineImages,
			onSerialize: (n) => {
				if (isSerializedIframe(n, mirror)) iframeManager.addIframe(n);
				if (isSerializedStylesheet(n, mirror)) stylesheetManager.trackLinkElement(n);
				if (hasShadowRoot(n)) shadowDomManager.addShadowRoot(src_default.shadowRoot(n), document);
			},
			onIframeLoad: (iframe, childSn) => {
				iframeManager.attachIframe(iframe, childSn);
				shadowDomManager.observeAttachShadow(iframe);
			},
			onStylesheetLoad: (linkEl, childSn) => {
				stylesheetManager.attachLinkElement(linkEl, childSn);
			},
			keepIframeSrcFn
		});
		if (!node) return console.warn("Failed to snapshot the document");
		wrappedEmit({
			type: EventType.FullSnapshot,
			data: {
				node,
				initialOffset: getWindowScroll(window)
			}
		}, isCheckout);
		canvasManager.unlock();
		mutationBuffers.forEach((buf) => buf.unlock());
		if (document.adoptedStyleSheets && document.adoptedStyleSheets.length > 0) stylesheetManager.adoptStyleSheets(document.adoptedStyleSheets, mirror.getId(document));
	};
	try {
		const handlers = [];
		const observe = (doc) => {
			return callbackWrapper(initObservers)({
				mutationCb: wrappedMutationEmit,
				mousemoveCb: (positions, source) => wrappedEmit({
					type: EventType.IncrementalSnapshot,
					data: {
						source,
						positions
					}
				}),
				mouseInteractionCb: (d) => wrappedEmit({
					type: EventType.IncrementalSnapshot,
					data: {
						source: IncrementalSource.MouseInteraction,
						...d
					}
				}),
				scrollCb: wrappedScrollEmit,
				viewportResizeCb: (d) => wrappedEmit({
					type: EventType.IncrementalSnapshot,
					data: {
						source: IncrementalSource.ViewportResize,
						...d
					}
				}),
				inputCb: (v) => wrappedEmit({
					type: EventType.IncrementalSnapshot,
					data: {
						source: IncrementalSource.Input,
						...v
					}
				}),
				mediaInteractionCb: (p) => wrappedEmit({
					type: EventType.IncrementalSnapshot,
					data: {
						source: IncrementalSource.MediaInteraction,
						...p
					}
				}),
				styleSheetRuleCb: (r) => wrappedEmit({
					type: EventType.IncrementalSnapshot,
					data: {
						source: IncrementalSource.StyleSheetRule,
						...r
					}
				}),
				styleDeclarationCb: (r) => wrappedEmit({
					type: EventType.IncrementalSnapshot,
					data: {
						source: IncrementalSource.StyleDeclaration,
						...r
					}
				}),
				canvasMutationCb: wrappedCanvasMutationEmit,
				fontCb: (p) => wrappedEmit({
					type: EventType.IncrementalSnapshot,
					data: {
						source: IncrementalSource.Font,
						...p
					}
				}),
				selectionCb: (p) => {
					wrappedEmit({
						type: EventType.IncrementalSnapshot,
						data: {
							source: IncrementalSource.Selection,
							...p
						}
					});
				},
				customElementCb: (c) => {
					wrappedEmit({
						type: EventType.IncrementalSnapshot,
						data: {
							source: IncrementalSource.CustomElement,
							...c
						}
					});
				},
				blockClass,
				ignoreClass,
				ignoreSelector,
				maskTextClass,
				maskTextSelector,
				maskInputOptions,
				inlineStylesheet,
				sampling,
				recordDOM,
				recordCanvas,
				inlineImages,
				userTriggeredOnInput,
				collectFonts,
				doc,
				maskInputFn,
				maskTextFn,
				keepIframeSrcFn,
				blockSelector,
				slimDOMOptions,
				dataURLOptions,
				mirror,
				iframeManager,
				stylesheetManager,
				shadowDomManager,
				processedNodeManager,
				canvasManager,
				ignoreCSSAttributes,
				plugins: plugins?.filter((p) => p.observer)?.map((p) => ({
					observer: p.observer,
					options: p.options,
					callback: (payload) => wrappedEmit({
						type: EventType.Plugin,
						data: {
							plugin: p.name,
							payload
						}
					})
				})) || []
			}, hooks);
		};
		const iframeObservers = /* @__PURE__ */ new Map();
		iframeManager.addLoadListener((iframeEl) => {
			try {
				const doc = iframeEl.contentDocument;
				if (iframeObservers.has(doc)) return;
				iframeObservers.set(doc, observe(doc));
			} catch (error) {
				console.warn(error);
			}
		});
		iframeManager.addUnloadListener((doc) => {
			const stopObserving = iframeObservers.get(doc);
			if (!stopObserving) return;
			iframeObservers.delete(doc);
			stopObserving();
			shadowDomManager.removeShadowRootsIn(doc);
			mirror.removeNodeFromMap(doc);
		});
		const init = () => {
			takeFullSnapshot();
			handlers.push(observe(document));
			recording = true;
		};
		if (["interactive", "complete"].includes(document.readyState)) init();
		else {
			handlers.push(on("DOMContentLoaded", () => {
				wrappedEmit({
					type: EventType.DomContentLoaded,
					data: {}
				});
				if (recordAfter === "DOMContentLoaded") init();
			}));
			handlers.push(on("load", () => {
				wrappedEmit({
					type: EventType.Load,
					data: {}
				});
				if (recordAfter === "load") init();
			}, window));
		}
		return () => {
			[...handlers, ...iframeObservers.values()].forEach((handler) => {
				try {
					handler();
				} catch (error) {
					/**
					* https://github.com/rrweb-io/rrweb/pull/1695
					* This error can occur in a known scenario:
					* If an iframe is initially same-origin and observed, but later its 
					location is changed in an opaque way to a cross-origin URL (perhaps within the iframe via its `document.location` or a redirect) 
					* attempting to execute the handler in the stop record function will 
					throw a "cannot access cross-origin frame" error.
					* This error is expected and can be safely ignored.
					*/
					if (!String(error).toLowerCase().includes("cross-origin")) console.warn(error);
				}
			});
			iframeObservers.clear();
			iframeManager.destroy();
			processedNodeManager.destroy();
			shadowDomManager.reset();
			canvasManager.reset();
			recording = false;
			unregisterErrorHandler();
		};
	} catch (error) {
		console.warn(error);
	}
}
record.addCustomEvent = (tag, payload) => {
	if (!recording) throw new Error("please add custom event after start recording");
	wrappedEmit({
		type: EventType.Custom,
		data: {
			tag,
			payload
		}
	});
};
record.addAnnotation = (annotation) => {
	if (!recording) throw new Error("please add annotation after recording started");
	wrappedEmit({
		type: EventType.Annotation,
		data: annotation
	});
};
record.freezePage = () => {
	canvasManager.freeze();
	mutationBuffers.forEach((buf) => buf.freeze());
};
record.takeFullSnapshot = (isCheckout) => {
	if (!recording) throw new Error("please take full snapshot after start recording");
	takeFullSnapshot(isCheckout);
};
record.mirror = mirror;
export { record };

//# sourceMappingURL=record.js.map