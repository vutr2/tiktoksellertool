// What the seller reads when a rule is broken.
//
// SPEC §10 asks for "the rule named in plain English" — so the English wording
// stays the definition, and Vietnamese is written to say the same thing with
// the same directness rather than to translate word for word.
//
// Every message is a function of the values it names. Building the sentence per
// language is the only way a translation can put the number, the marketplace
// and the limit where its own grammar wants them.

export type MessageLanguage = "en" | "vi";

export interface RuleCopy {
  imageSlot(slot: "main" | "secondary"): string;
  contentLabel(item: string): string;

  aspectRatio(name: string, ratio: string, slot: string): string;
  imageSize(width: number, height: number): string;
  minLongestEdge(name: string, slot: string, px: number): string;
  maxLongestEdge(name: string, slot: string, px: number): string;

  backgroundUnknown(name: string, slot: string): string;
  backgroundUnmeasured(): string;
  backgroundNotWhite(name: string, slot: string): string;
  backgroundColour(r: number, g: number, b: number): string;

  fillUnknown(): string;
  fillExpectation(name: string, min: string): string;
  fillTooSmall(name: string, min: string, slot: string): string;
  fillTooLarge(name: string, max: string, slot: string): string;
  fillActual(actual: string): string;

  contentUnchecked(name: string, slot: string): string;
  contentForbids(name: string, items: string): string;
  contentNotAllowed(name: string, item: string, slot: string): string;

  titleTooLong(name: string, max: number): string;
  titleLengthOver(length: number, over: number): string;
  titleTooShort(name: string, min: number): string;
  titleLength(length: number): string;
  titleAllCaps(name: string): string;
  titlePromo(name: string): string;
  titlePromoFound(found: string): string;
  titlePromoUnchecked(name: string): string;
  titlePromoUncheckedDetail(): string;

  descriptionNeedsBullets(name: string): string;
  descriptionIsOneBlock(): string;
  descriptionTooManyBullets(name: string, max: number): string;
  descriptionBulletCount(count: number): string;
  descriptionBulletTooLong(name: string, max: number): string;
  descriptionBulletLength(index: number, length: number): string;
  descriptionTooLong(name: string, max: number): string;
  descriptionLength(length: number): string;
}

const EN: RuleCopy = {
  imageSlot: (slot) => (slot === "main" ? "main image" : "secondary image"),
  contentLabel: (item) => ({
    text: "overlay text", logo: "logos", watermark: "watermarks",
    border: "borders", human: "people",
  } as Record<string, string>)[item] ?? item,

  aspectRatio: (name, ratio, slot) => `${name} requires a ${ratio} ${slot}.`,
  imageSize: (w, h) => `This image is ${w}×${h}.`,
  minLongestEdge: (name, slot, px) =>
    `${name} needs the ${slot} to be at least ${px}px on its longest side.`,
  maxLongestEdge: (name, slot, px) =>
    `${name} caps the ${slot} at ${px}px on its longest side.`,

  backgroundUnknown: (name, slot) =>
    `We could not confirm the background is pure white, which ${name} requires on the ${slot}.`,
  backgroundUnmeasured: () => "The background colour has not been measured yet.",
  backgroundNotWhite: (name, slot) => `${name} requires a pure white background on the ${slot}.`,
  backgroundColour: (r, g, b) => `This background is RGB ${r}/${g}/${b}.`,

  fillUnknown: () => "We could not confirm how much of the frame the product fills.",
  fillExpectation: (name, min) => `${name} expects at least ${min}.`,
  fillTooSmall: (name, min, slot) =>
    `${name} expects the product to fill at least ${min} of the ${slot}.`,
  fillTooLarge: (name, max, slot) =>
    `${name} expects the product to fill no more than ${max} of the ${slot}.`,
  fillActual: (actual) => `It currently fills ${actual}.`,

  contentUnchecked: (name, slot) =>
    `This image has not been checked for things ${name} does not allow on the ${slot}.`,
  contentForbids: (name, items) => `${name} forbids: ${items}.`,
  contentNotAllowed: (name, item, slot) => `${name} does not allow ${item} on the ${slot}.`,

  titleTooLong: (name, max) => `${name} allows ${max} characters in a title.`,
  titleLengthOver: (length, over) => `This title is ${length} characters — ${over} over.`,
  titleTooShort: (name, min) => `${name} expects at least ${min} characters in a title.`,
  titleLength: (length) => `This title is ${length} characters.`,
  titleAllCaps: (name) => `${name} does not allow titles in all capitals.`,
  titlePromo: (name) => `${name} does not allow promotional wording in a title.`,
  titlePromoFound: (found) => `Found: ${found}.`,
  titlePromoUnchecked: (name) =>
    `We could not check this title for promotional wording, which ${name} does not allow.`,
  titlePromoUncheckedDetail: () =>
    "Our wording list only covers English. Read this title yourself before you publish it.",

  descriptionNeedsBullets: (name) => `${name} expects the description as bullet points.`,
  descriptionIsOneBlock: () => "This description is a single block of text.",
  descriptionTooManyBullets: (name, max) => `${name} allows ${max} bullet points.`,
  descriptionBulletCount: (count) => `This description has ${count}.`,
  descriptionBulletTooLong: (name, max) =>
    `${name} allows ${max} characters per bullet point.`,
  descriptionBulletLength: (index, length) => `Bullet ${index} is ${length} characters.`,
  descriptionTooLong: (name, max) => `${name} allows ${max} characters in a description.`,
  descriptionLength: (length) => `This description is ${length} characters.`,
};

const VI: RuleCopy = {
  imageSlot: (slot) => (slot === "main" ? "ảnh chính" : "ảnh phụ"),
  contentLabel: (item) => ({
    text: "chữ chèn lên ảnh", logo: "logo", watermark: "watermark",
    border: "viền khung", human: "hình người",
  } as Record<string, string>)[item] ?? item,

  aspectRatio: (name, ratio, slot) => `${name} yêu cầu ${slot} theo tỉ lệ ${ratio}.`,
  imageSize: (w, h) => `Ảnh này là ${w}×${h}.`,
  minLongestEdge: (name, slot, px) =>
    `${name} yêu cầu cạnh dài nhất của ${slot} tối thiểu ${px}px.`,
  maxLongestEdge: (name, slot, px) =>
    `${name} giới hạn cạnh dài nhất của ${slot} ở mức ${px}px.`,

  backgroundUnknown: (name, slot) =>
    `Chúng tôi chưa xác nhận được nền có trắng tinh hay không, trong khi ${name} yêu cầu điều đó cho ${slot}.`,
  backgroundUnmeasured: () => "Màu nền chưa được đo.",
  backgroundNotWhite: (name, slot) => `${name} yêu cầu nền trắng tinh cho ${slot}.`,
  backgroundColour: (r, g, b) => `Nền này là RGB ${r}/${g}/${b}.`,

  fillUnknown: () => "Chúng tôi chưa xác nhận được sản phẩm chiếm bao nhiêu phần khung hình.",
  fillExpectation: (name, min) => `${name} yêu cầu tối thiểu ${min}.`,
  fillTooSmall: (name, min, slot) =>
    `${name} yêu cầu sản phẩm chiếm ít nhất ${min} của ${slot}.`,
  fillTooLarge: (name, max, slot) =>
    `${name} yêu cầu sản phẩm chiếm không quá ${max} của ${slot}.`,
  fillActual: (actual) => `Hiện đang chiếm ${actual}.`,

  contentUnchecked: (name, slot) =>
    `Ảnh này chưa được kiểm tra những thứ mà ${name} không cho phép trên ${slot}.`,
  contentForbids: (name, items) => `${name} cấm: ${items}.`,
  contentNotAllowed: (name, item, slot) => `${name} không cho phép ${item} trên ${slot}.`,

  titleTooLong: (name, max) => `${name} chỉ cho phép ${max} ký tự trong tiêu đề.`,
  titleLengthOver: (length, over) => `Tiêu đề này dài ${length} ký tự — thừa ${over}.`,
  titleTooShort: (name, min) => `${name} yêu cầu tiêu đề có ít nhất ${min} ký tự.`,
  titleLength: (length) => `Tiêu đề này dài ${length} ký tự.`,
  titleAllCaps: (name) => `${name} không cho phép tiêu đề viết hoa toàn bộ.`,
  titlePromo: (name) => `${name} không cho phép từ ngữ quảng cáo trong tiêu đề.`,
  titlePromoFound: (found) => `Đã tìm thấy: ${found}.`,
  titlePromoUnchecked: (name) =>
    `Chúng tôi chưa kiểm tra được từ ngữ quảng cáo trong tiêu đề này, trong khi ${name} không cho phép.`,
  titlePromoUncheckedDetail: () =>
    "Danh sách từ ngữ của chúng tôi mới chỉ có tiếng Anh. Hãy tự đọc lại tiêu đề này trước khi đăng.",

  descriptionNeedsBullets: (name) => `${name} yêu cầu mô tả ở dạng gạch đầu dòng.`,
  descriptionIsOneBlock: () => "Mô tả này đang là một khối chữ liền.",
  descriptionTooManyBullets: (name, max) => `${name} chỉ cho phép ${max} gạch đầu dòng.`,
  descriptionBulletCount: (count) => `Mô tả này có ${count}.`,
  descriptionBulletTooLong: (name, max) =>
    `${name} chỉ cho phép ${max} ký tự mỗi gạch đầu dòng.`,
  descriptionBulletLength: (index, length) => `Gạch đầu dòng ${index} dài ${length} ký tự.`,
  descriptionTooLong: (name, max) => `${name} chỉ cho phép ${max} ký tự trong mô tả.`,
  descriptionLength: (length) => `Mô tả này dài ${length} ký tự.`,
};

export function ruleCopy(language: string): RuleCopy {
  return language === "vi" ? VI : EN;
}
