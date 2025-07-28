typedef struct{
   kType key;
   vType value;
   } KVPair#(type kType, type vType) deriving(Bits, Eq, FShow);

instance Ord#(KVPair#(kType, vType)) provisos (Ord#(kType),
   Alias#(KVPair#(kType, vType), data_t));
   function Bool \< (data_t x, data_t y) = (x.key < y.key);
   function Bool \<= (data_t x, data_t y) = (x.key <= y.key);
   function Bool \> (data_t x, data_t y) = (x.key > y.key);
   function Bool \>= (data_t x, data_t y) = (x.key >= y.key);
   function Ordering compare(data_t x, data_t y) = compare(x.key, y.key);
   function data_t min(data_t x, data_t y) = (x.key<=y.key)?x:y;
   function data_t max(data_t x, data_t y) = (x.key<=y.key)?y:x;
endinstance

instance Bounded#(KVPair#(kType, vType)) provisos (Bounded#(kType), Bounded#(vType));
   minBound = KVPair{key:minBound, value:minBound};
   maxBound = KVPair{key:maxBound, value:maxBound};
endinstance

