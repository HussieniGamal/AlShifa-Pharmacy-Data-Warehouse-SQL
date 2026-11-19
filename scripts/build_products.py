"""
Build the Al Shifa Al Ajil product master from two public reference lists:

  data/reference/sfda_drugs_raw.txt      - drugs and official public prices from the
                                           Saudi Food & Drug Authority (SFDA) drugs list
  data/reference/retail_products_raw.txt - beauty, care, vitamin and device items with
                                           shelf prices seen on a Saudi pharmacy retail website

Output: data/reference/products.csv  (one row per sellable item)

Prices are real reference prices. Unit costs, flags and the private-label range are
assumptions made for this portfolio project.
"""
from pathlib import Path
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / "data" / "reference"
rng = np.random.default_rng(7)

# ---------------------------------------------------------------- pharmaceuticals
# match_key -> (therapeutic_class, department, is_rx, is_chronic)
DRUG_CLASS = {}
def add(keys, cls, dept, rx, chronic):
    for k in keys.split():
        DRUG_CLASS[k] = (cls, dept, rx, chronic)

add("PARACETAMOL IBUPROFEN DICLOFENAC NAPROXEN MEFENAMIC ACETYLSALICYLIC", "Pain & Fever", "OTC Medicines", 0, 0)
add("CELECOXIB ETORICOXIB", "Pain & Fever", "Prescription Medicines", 1, 0)
add("PSEUDOEPHEDRINE CHLORPHENIRAMINE DEXTROMETHORPHAN GUAIFENESIN AMBROXOL BROMHEXINE XYLOMETAZOLINE OXYMETAZOLINE CARBOCISTEINE",
    "Cold, Cough & Flu", "OTC Medicines", 0, 0)
add("CETIRIZINE LORATADINE FEXOFENADINE", "Allergy", "OTC Medicines", 0, 0)
add("AMOXICILLIN AZITHROMYCIN CLARITHROMYCIN CEFUROXIME CEFIXIME CEFPROZIL CEFALEXIN CIPROFLOXACIN LEVOFLOXACIN METRONIDAZOLE NITROFURANTOIN FOSFOMYCIN DOXYCYCLINE",
    "Antibiotics", "Prescription Medicines", 1, 0)
add("OMEPRAZOLE ESOMEPRAZOLE PANTOPRAZOLE LANSOPRAZOLE RABEPRAZOLE FAMOTIDINE DOMPERIDONE MEBEVERINE",
    "Digestive Health", "Prescription Medicines", 1, 0)
add("LOPERAMIDE HYOSCINE LACTULOSE BISACODYL SIMETICONE ALGINATE MAGNESIUM", "Digestive Health", "OTC Medicines", 0, 0)
add("METFORMIN GLICLAZIDE GLIMEPIRIDE SITAGLIPTIN VILDAGLIPTIN LINAGLIPTIN EMPAGLIFLOZIN DAPAGLIFLOZIN PIOGLITAZONE INSULIN SEMAGLUTIDE LIRAGLUTIDE DULAGLUTIDE",
    "Diabetes", "Prescription Medicines", 1, 1)
add("AMLODIPINE VALSARTAN LOSARTAN IRBESARTAN CANDESARTAN TELMISARTAN OLMESARTAN BISOPROLOL CARVEDILOL ATENOLOL LISINOPRIL PERINDOPRIL INDAPAMIDE FUROSEMIDE SPIRONOLACTONE",
    "Hypertension & Heart", "Prescription Medicines", 1, 1)
add("CLOPIDOGREL APIXABAN RIVAROXABAN WARFARIN ENOXAPARIN", "Blood Thinners", "Prescription Medicines", 1, 1)
add("ATORVASTATIN ROSUVASTATIN SIMVASTATIN FENOFIBRATE EZETIMIBE", "Cholesterol", "Prescription Medicines", 1, 1)
add("SALBUTAMOL BUDESONIDE TIOTROPIUM MONTELUKAST", "Asthma & COPD", "Prescription Medicines", 1, 1)
add("LEVOTHYROXINE CARBIMAZOLE", "Thyroid", "Prescription Medicines", 1, 1)
add("SERTRALINE ESCITALOPRAM FLUOXETINE VENLAFAXINE PREGABALIN GABAPENTIN LEVETIRACETAM LAMOTRIGINE",
    "Neurology & Mental Health", "Prescription Medicines", 1, 1)
add("CHOLECALCIFEROL FOLIC FERROUS CALCIUM CYANOCOBALAMIN OMEGA", "Vitamins & Minerals", "Vitamins & Supplements", 0, 0)
add("HYDROCORTISONE BETAMETHASONE MOMETASONE FLUTICASONE FUSIDIC MUPIROCIN ADAPALENE PERMETHRIN",
    "Dermatology", "Prescription Medicines", 1, 0)
add("CLOTRIMAZOLE MICONAZOLE TERBINAFINE KETOCONAZOLE BENZOYL ZINC", "Dermatology", "OTC Medicines", 0, 0)
add("FLUCONAZOLE VALACICLOVIR OSELTAMIVIR ALBENDAZOLE MEBENDAZOLE", "Anti-infectives", "Prescription Medicines", 1, 0)
add("OLOPATADINE HYPROMELLOSE", "Eye Care", "OTC Medicines", 0, 0)
add("TAMSULOSIN FINASTERIDE SOLIFENACIN", "Urology", "Prescription Medicines", 1, 1)
add("SILDENAFIL TADALAFIL", "Men's Health", "Prescription Medicines", 1, 0)
add("PROGESTERONE DYDROGESTERONE DROSPIRENONE", "Women's Health", "Prescription Medicines", 1, 0)
add("TIZANIDINE GLUCOSAMINE ALLOPURINOL FEBUXOSTAT", "Bones & Joints", "Prescription Medicines", 1, 1)
add("NICOTINE", "Smoking Cessation", "OTC Medicines", 0, 0)

COLD_CHAIN = {"INSULIN", "SEMAGLUTIDE", "LIRAGLUTIDE", "DULAGLUTIDE"}

drugs = pd.read_csv(REF / "sfda_drugs_raw.txt", sep="|", dtype=str)
drugs["public_price_sar"] = drugs["public_price_sar"].astype(float)
# drop price outliers inside a molecule (usually hospital or bulk packs)
med = drugs.groupby("match_key")["public_price_sar"].transform("median")
drugs = drugs[drugs["public_price_sar"] <= med * 3].copy()
drugs = drugs[drugs["match_key"].isin(DRUG_CLASS)]

cls = drugs["match_key"].map(DRUG_CLASS)
drugs["therapeutic_class"] = cls.str[0]
drugs["department"] = cls.str[1]
drugs["is_rx"] = cls.str[2]
drugs["is_chronic"] = cls.str[3]
# Rybelsus is oral, so not cold chain
drugs["is_cold_chain"] = (drugs["match_key"].isin(COLD_CHAIN) &
                          ~drugs["dosage_form"].str.contains("Tablet", case=False)).astype(int)
drugs["category"] = drugs["therapeutic_class"]
drugs["brand"] = drugs["trade_name"].str.split().str[0].str.title()
drugs["product_name"] = (drugs["trade_name"].str.strip() + " " + drugs["strength"].str.strip()
                         + " - " + drugs["dosage_form"].str.strip())
drugs["list_price_sar"] = drugs["public_price_sar"]
drugs["source"] = "SFDA drugs list"
drugs = drugs.drop_duplicates("product_name")

# --------------------------------------------------------------- retail products
RETAIL_MAP = {  # source department -> (our department, our category)
    "fragrances": ("Fragrances", None),
    "makeup": ("Beauty & Skincare", "Makeup"),
    "skin-care": ("Beauty & Skincare", None),
    "hair-care": ("Personal Care", "Hair Care"),
    "men-care": ("Personal Care", "Men's Grooming"),
    "lady-care": ("Personal Care", "Feminine Care"),
    "baby-care": ("Baby & Mother", "Baby Care"),
    "vitamin-supplement": ("Vitamins & Supplements", None),
    "healthy-devices": ("Medical Devices", None),
    "braces-supports-recovery": ("Medical Devices", "Supports & Recovery"),
    "first-aid-wound-care": ("Medical Devices", "First Aid"),
    "seniors-care": ("Medical Devices", "Seniors Care"),
    "healthy-nutrition": ("Health Food", None),
}
retail = pd.read_csv(REF / "retail_products_raw.txt", sep="|", dtype=str)
retail["list_price_sar"] = retail["list_price_sar"].astype(float)
src_dept = retail["department"].copy()
src_cat = retail["category"].str.replace("-", " ").str.title()
retail["department"] = src_dept.map(lambda d: RETAIL_MAP[d][0])
retail["category"] = [RETAIL_MAP[d][1] or c for d, c in zip(src_dept, src_cat)]
retail["sub_category"] = src_cat
retail["therapeutic_class"] = None
retail["scientific_name"] = None
retail["dosage_form"] = None
retail["strength"] = None
retail["is_rx"] = 0
retail["is_chronic"] = 0
retail["is_cold_chain"] = 0
retail["source"] = "Retail website reference"
drugs["sub_category"] = drugs["scientific_name"].str.split(",").str[0].str.title()

# --------------------------------------------------------- private label (invented)
private = pd.DataFrame([
    ("Al Shifa Cotton Pads 100 pcs", "Beauty & Skincare", "Makeup", "Make Up Tools", 9.95),
    ("Al Shifa Cotton Buds 200 pcs", "Personal Care", "Hygiene", "Cotton & Buds", 7.95),
    ("Al Shifa Hand Sanitizer Gel 500 ml", "Personal Care", "Hygiene", "Sanitizers", 14.95),
    ("Al Shifa Antibacterial Wet Wipes 72 pcs", "Personal Care", "Hygiene", "Wipes", 11.50),
    ("Al Shifa Baby Wipes Sensitive 80 pcs", "Baby & Mother", "Baby Care", "Baby Wipes", 9.50),
    ("Al Shifa Vitamin C 1000 mg Effervescent 20 Tablets", "Vitamins & Supplements", "Immunity", "Vitamin C", 18.95),
    ("Al Shifa Vitamin D3 5000 IU 60 Softgels", "Vitamins & Supplements", "Vitamins & Minerals", "Vitamin D", 34.95),
    ("Al Shifa Zinc 50 mg 60 Tablets", "Vitamins & Supplements", "Immunity", "Zinc", 24.95),
    ("Al Shifa Medical Face Mask 50 pcs", "Medical Devices", "First Aid", "Face Masks", 12.95),
    ("Al Shifa Elastic Bandage 10 cm", "Medical Devices", "First Aid", "Bandages", 8.50),
    ("Al Shifa Adhesive Plasters 40 pcs", "Medical Devices", "First Aid", "Plasters", 9.95),
    ("Al Shifa Digital Thermometer", "Medical Devices", "Thermometers", "Thermometers", 19.95),
    ("Al Shifa Saline Nasal Spray 30 ml", "OTC Medicines", "Cold, Cough & Flu", "Saline", 12.50),
    ("Al Shifa Lip Balm SPF15", "Beauty & Skincare", "Lip Care", "Lip Balm", 9.95),
    ("Al Shifa Sunscreen Lotion SPF50 100 ml", "Beauty & Skincare", "Sun Care", "Sun Care", 39.95),
], columns=["product_name", "department", "category", "sub_category", "list_price_sar"])
private["brand"] = "Al Shifa"
private["source"] = "Private label (invented)"
for c in ["therapeutic_class", "scientific_name", "dosage_form", "strength"]:
    private[c] = None
private[["is_rx", "is_chronic", "is_cold_chain"]] = 0

cols = ["product_name", "brand", "department", "category", "sub_category", "therapeutic_class",
        "scientific_name", "dosage_form", "strength", "is_rx", "is_chronic", "is_cold_chain",
        "list_price_sar", "source"]
prod = pd.concat([drugs[cols], retail[cols], private[cols]], ignore_index=True)
prod["is_private_label"] = (prod["brand"] == "Al Shifa").astype(int)

# ------------------------------------------------------------ unit cost (assumed)
# Rx margins are regulated and thin; retail and private label margins are wider.
margin = np.select(
    [prod["is_private_label"] == 1, prod["department"] == "Prescription Medicines",
     prod["department"] == "OTC Medicines", prod["department"] == "Fragrances",
     prod["department"].isin(["Beauty & Skincare", "Personal Care"]),
     prod["department"] == "Medical Devices"],
    [0.55, 0.22, 0.30, 0.38, 0.40, 0.33], default=0.35)
margin = np.clip(margin + rng.normal(0, 0.03, len(prod)), 0.10, 0.70)
prod["unit_cost_sar"] = (prod["list_price_sar"] * (1 - margin)).round(2)

# shelf life in months (assumed) - drives expiry analysis
prod["shelf_life_months"] = np.select(
    [prod["is_cold_chain"] == 1, prod["department"].isin(["Prescription Medicines", "OTC Medicines"]),
     prod["department"] == "Health Food", prod["department"] == "Vitamins & Supplements",
     prod["department"] == "Medical Devices"],
    [12, 30, 12, 24, 60], default=36)
prod.loc[prod["dosage_form"].fillna("").str.contains("Powder for oral suspension|Syrup", case=False),
         "shelf_life_months"] = 18

prod = prod.sort_values(["department", "category", "product_name"]).reset_index(drop=True)
prod.insert(0, "product_code", [f"P{100001 + i}" for i in range(len(prod))])
prod.to_csv(REF / "products.csv", index=False)
print(len(prod), "products")
print(prod.groupby("department").size().to_string())
